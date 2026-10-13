import Foundation

extension CatalogCompiler {
    /// dimension2 values actool gives each icon size (in points).
    static let iconSizeIndex: [Double: UInt16] = [20: 1, 29: 2, 40: 3, 60: 4, 76: 5, 83.5: 6, 1024: 8]

    struct IconEntry {
        var file: String
        var size: Double
        var scale: Int
        var idiom: String
        var variant: Variant
    }

    func compileAppIconSet(_ asset: Asset, primary: Bool) throws {
        var entries: [IconEntry] = []
        for obj in (asset.contents["images"]?.array ?? []).compactMap(\.object) {
            guard let file = obj["filename"]?.string else { continue }
            let idiom = obj["idiom"]?.string ?? "universal"
            if let platform = obj["platform"]?.string, !["ios", "iphoneos"].contains(platform), idiom == "universal" { continue }
            let sizeString = obj["size"]?.string ?? "1024x1024"
            let size = Double(sizeString.split(separator: "x").first.map(String.init) ?? "") ?? 1024
            let scale = obj["scale"]?.string.flatMap { Int($0.replacingOccurrences(of: "x", with: "")) } ?? 1
            var probe = obj
            probe["idiom"] = .string("universal")
            guard let v = variant(of: probe, assetName: asset.name) else { continue }
            entries.append(IconEntry(file: file, size: size, scale: scale, idiom: idiom, variant: v))
        }
        let idioms = appIconIdioms.filter { $0 == 1 || $0 == 2 }
        var images: [String: Bitmap] = [:]
        func load(_ file: String) throws -> Bitmap {
            if let b = images[file] { return b }
            let url = asset.directory.appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw Bitmap.Error.decode("\(asset.name)/\(file)")
            }
            let b = try Bitmap.decode(data, name: file)
            images[file] = b
            return b
        }

        let universal = entries.filter { $0.idiom == "universal" }
        var produced = false
        if !universal.isEmpty {
            // Single-size icon: one 1024pt image per appearance, listed for each device idiom.
            for idiom in idioms {
                var sism = CSIRendition(key: [:], layout: CSILayout.multisizeImageSet, name: asset.name,
                                        payload: CSIPayload.multisize([(1024, 1024, 1, 0)]))
                sism.key = baseKey(asset.name, part: CARPart.multisizeImageSet)
                sism.key[.idiom] = idiom
                sism.key[.scale] = 1
                sism.info = [CSIInfoBuilder.composition(opacity: 0), CSIInfoBuilder.bitmapInfo()]
                writer.renditions.append(sism)
                for e in universal {
                    let bitmap = try load(e.file)
                    var k = key(asset.name, part: CARPart.appIcon, variant: e.variant, scale: 1)
                    k[.idiom] = idiom
                    k[.dimension2] = 1
                    writer.renditions.append(rasterRendition(bitmap, key: k, name: e.file, scale: 1, flags: 0, resizing: nil, alignment: nil))
                }
            }
            produced = true
        } else {
            let idiomOf: [String: UInt16] = ["iphone": 1, "ipad": 2, "ios-marketing": 6]
            var sizesByIdiom: [UInt16: [(Double, UInt16)]] = [:]
            for e in entries {
                guard let idiom = idiomOf[e.idiom], idiom == 6 || idioms.contains(idiom), let index = Self.iconSizeIndex[e.size] else { continue }
                let bitmap = try load(e.file)
                var k = key(asset.name, part: CARPart.appIcon, variant: e.variant, scale: UInt16(e.scale))
                k[.idiom] = idiom
                k[.dimension2] = index
                writer.renditions.append(rasterRendition(bitmap, key: k, name: e.file, scale: e.scale, flags: 0, resizing: nil, alignment: nil))
                if !(sizesByIdiom[idiom]?.contains { $0.1 == index } ?? false) { sizesByIdiom[idiom, default: []].append((e.size, index)) }
                produced = true
            }
            // actool also files the iPhone 60pt @3x icon as a 2x icon for subtype 1792 (iPhone XR class screens).
            if idioms.contains(1), let xr = entries.first(where: { $0.idiom == "iphone" && $0.size == 60 && $0.scale == 3 }) {
                let bitmap = try load(xr.file)
                var k = key(asset.name, part: CARPart.appIcon, variant: xr.variant, scale: 2)
                k[.idiom] = 1
                k[.subtype] = 1792
                k[.dimension2] = 7
                writer.renditions.append(rasterRendition(bitmap, key: k, name: xr.file, scale: 2, flags: 0, resizing: nil, alignment: nil))
                var sism = CSIRendition(key: baseKey(asset.name, part: CARPart.multisizeImageSet), layout: CSILayout.multisizeImageSet, name: asset.name,
                                        payload: CSIPayload.multisize([(90, 90, 7, 0)]))
                sism.key[.idiom] = 1
                sism.key[.subtype] = 1792
                sism.key[.scale] = 1
                sism.info = [CSIInfoBuilder.composition(opacity: 0), CSIInfoBuilder.bitmapInfo()]
                writer.renditions.append(sism)
            }
            for (idiom, sizes) in sizesByIdiom {
                let list = sizes.sorted { $0.1 < $1.1 }.map { (UInt32($0.0), UInt32($0.0), $0.1, UInt16(0)) }
                var sism = CSIRendition(key: baseKey(asset.name, part: CARPart.multisizeImageSet), layout: CSILayout.multisizeImageSet, name: asset.name,
                                        payload: CSIPayload.multisize(list.map { (width: $0.0, height: $0.1, index: $0.2, idiom: $0.3) }))
                sism.key[.idiom] = idiom
                sism.key[.scale] = 1
                sism.info = [CSIInfoBuilder.composition(opacity: 0), CSIInfoBuilder.bitmapInfo()]
                writer.renditions.append(sism)
            }
        }
        guard produced else { return }
        addFacet(asset.name, part: CARPart.appIcon)

        let phone = idioms.contains(1), pad = idioms.contains(2)
        var iconsKey: [String] = []
        if phone || (!phone && !pad) { iconsKey.append("CFBundleIcons") }
        if pad { iconsKey.append("CFBundleIcons~ipad") }

        if primary {
            func iconBitmap(points: Double, scale: Int, preferIdiom: String) throws -> Bitmap? {
                let px = Int(points * Double(scale))
                let anyAppearance = entries.filter { $0.variant.appearance == 0 }
                if let exact = anyAppearance.first(where: { $0.idiom == preferIdiom && $0.size == points && $0.scale == scale }) {
                    return try load(exact.file).resized(width: px, height: px)
                }
                let candidates = anyAppearance.sorted { $0.size * Double($0.scale) > $1.size * Double($1.scale) }
                guard let best = candidates.first else { return nil }
                return try load(best.file).resized(width: px, height: px)
            }
            if phone || pad, let b = try iconBitmap(points: 60, scale: 2, preferIdiom: "iphone") {
                files.append(("\(asset.name)60x60@2x.png", try b.pngData()))
            }
            if pad, let b = try iconBitmap(points: 76, scale: 2, preferIdiom: "ipad") {
                files.append(("\(asset.name)76x76@2x~ipad.png", try b.pngData()))
            }
            for k in iconsKey {
                var dict = plist[k] as? [String: Any] ?? [:]
                var iconFiles = ["\(asset.name)60x60"]
                if k == "CFBundleIcons~ipad" { iconFiles.append("\(asset.name)76x76") }
                dict["CFBundlePrimaryIcon"] = ["CFBundleIconFiles": iconFiles, "CFBundleIconName": asset.name] as [String: Any]
                plist[k] = dict
            }
        } else {
            for k in iconsKey {
                var dict = plist[k] as? [String: Any] ?? [:]
                var alternates = dict["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
                alternates[asset.name] = ["CFBundleIconName": asset.name]
                dict["CFBundleAlternateIcons"] = alternates
                plist[k] = dict
            }
        }
    }
}
