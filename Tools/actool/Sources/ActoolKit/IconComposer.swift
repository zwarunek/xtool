import Foundation

/// An Icon Composer document (`.icon`): a fill and image layers that actool flattens into the app icon.
///
/// This tool composites the fill and the visible layers at 1024x1024 (no Liquid Glass shading and no layered
/// icon stack), which gives SpringBoard and the Info.plist icon files a correct, flat icon.
public struct IconComposerIcon: Sendable {
    public var url: URL
    public var name: String
    public var document: [String: JSONValue]

    public init(url: URL) throws {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        let data = try Data(contentsOf: url.appendingPathComponent("icon.json"))
        document = try JSONValue.parse(data).object ?? [:]
    }

    public var inputPaths: [String] {
        var paths = [url.path, url.appendingPathComponent("icon.json").path]
        let assets = url.appendingPathComponent("Assets")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: assets.path) {
            paths += files.sorted().map { assets.appendingPathComponent($0).path }
        }
        return paths
    }

    /// Parses "srgb:r,g,b,a" or "display-p3:r,g,b,a" (and "gray:w,a") fill colors into straight RGBA.
    static func color(_ spec: String?) -> (Double, Double, Double, Double)? {
        guard let spec, let colon = spec.firstIndex(of: ":") else { return nil }
        let comps = spec[spec.index(after: colon)...].split(separator: ",").compactMap { Double($0) }
        switch comps.count {
        case 2: return (comps[0], comps[0], comps[0], comps[1])
        case 4: return (comps[0], comps[1], comps[2], comps[3])
        default: return nil
        }
    }

    /// Composites the icon at `size` pixels.
    public func flatten(size: Int = 1024) throws -> Bitmap {
        var canvas = Bitmap(width: size, height: size)
        if let fill = document["fill"]?.object {
            var color = Self.color(fill["solid"]?.string)
            if color == nil, let gradient = fill["automatic-gradient"]?.string ?? fill["linear-gradient"]?.array?.first?.string {
                color = Self.color(gradient)
            }
            if let (r, g, b, a) = color {
                let px: [UInt8] = [UInt8((b * a * 255).rounded()), UInt8((g * a * 255).rounded()), UInt8((r * a * 255).rounded()), UInt8((a * 255).rounded())]
                for i in stride(from: 0, to: canvas.pixels.count, by: 4) {
                    canvas.pixels[i] = px[0]; canvas.pixels[i + 1] = px[1]; canvas.pixels[i + 2] = px[2]; canvas.pixels[i + 3] = px[3]
                }
            }
        }
        // Groups and layers are listed front to back.
        let groups = (document["groups"]?.array ?? []).compactMap(\.object)
        for group in groups.reversed() where !(group["hidden"]?.bool ?? false) {
            let groupOpacity = group["opacity"]?.double ?? 1
            for layer in (group["layers"]?.array ?? []).compactMap(\.object).reversed() where !(layer["hidden"]?.bool ?? false) {
                guard let imageName = layer["image-name"]?.string else { continue }
                let file = url.appendingPathComponent("Assets").appendingPathComponent(imageName)
                guard let data = FileManager.default.contents(atPath: file.path) else { continue }
                let position = layer["position"]?.object ?? [:]
                let scale = position["scale"]?.double ?? 1
                let translation = position["translation-in-points"]?.array?.compactMap(\.double) ?? [0, 0]
                var image: Bitmap
                if imageName.lowercased().hasSuffix(".svg") {
                    let intrinsic = Bitmap.svgSize(data) ?? (1024, 1024)
                    let factor = Double(size) / 1024 * scale
                    image = try Bitmap.renderSVG(data, width: max(1, Int((intrinsic.width * factor).rounded())), height: max(1, Int((intrinsic.height * factor).rounded())), scale: factor)
                } else {
                    let decoded = try Bitmap.decode(data, name: imageName)
                    // Raster layers are authored at 1024 points per canvas.
                    let w = max(1, Int((Double(decoded.width) * Double(size) / 1024 * scale).rounded()))
                    let h = max(1, Int((Double(decoded.height) * Double(size) / 1024 * scale).rounded()))
                    image = try decoded.resized(width: w, height: h)
                }
                let opacity = (layer["opacity"]?.double ?? 1) * groupOpacity
                let ox = (size - image.width) / 2 + Int((translation.first ?? 0) * Double(size) / 1024)
                let oy = (size - image.height) / 2 + Int((translation.count > 1 ? translation[1] : 0) * Double(size) / 1024)
                canvas.blend(image, x: ox, y: oy, opacity: opacity)
            }
        }
        return canvas
    }
}

extension Bitmap {
    /// Source-over compositing of a premultiplied bitmap.
    mutating func blend(_ src: Bitmap, x: Int, y: Int, opacity: Double) {
        let o = UInt32(max(0, min(255, (opacity * 255).rounded())))
        for sy in 0..<src.height {
            let dy = y + sy
            guard dy >= 0, dy < height else { continue }
            for sx in 0..<src.width {
                let dx = x + sx
                guard dx >= 0, dx < width else { continue }
                let s = (sy * src.width + sx) * 4, d = (dy * width + dx) * 4
                let sa = UInt32(src.pixels[s + 3]) * o / 255
                if sa == 0 { continue }
                for c in 0..<4 {
                    let sc = UInt32(src.pixels[s + c]) * o / 255
                    pixels[d + c] = UInt8(min(255, sc + UInt32(pixels[d + c]) * (255 - sa) / 255))
                }
            }
        }
    }
}

extension CatalogCompiler {
    /// Compiles an Icon Composer icon named by --app-icon or --alternate-app-icon as a single-size app icon.
    func compileIconComposerIcon(_ icon: IconComposerIcon, primary: Bool) throws {
        let flat = try icon.flatten()
        let idioms = appIconIdioms.filter { $0 == 1 || $0 == 2 }
        for idiom in idioms {
            var sism = CSIRendition(key: baseKey(icon.name, part: CARPart.multisizeImageSet), layout: CSILayout.multisizeImageSet, name: icon.name,
                                    payload: CSIPayload.multisize([(1024, 1024, 1, 0)]))
            sism.key[.idiom] = idiom
            sism.key[.scale] = 1
            sism.info = [CSIInfoBuilder.composition(opacity: 0), CSIInfoBuilder.bitmapInfo()]
            writer.renditions.append(sism)
            var k = baseKey(icon.name, part: CARPart.appIcon)
            k[.idiom] = idiom
            k[.scale] = 1
            k[.dimension2] = 1
            writer.renditions.append(rasterRendition(flat, key: k, name: "\(icon.name)1024x1024.png", scale: 1, flags: 0, resizing: nil, alignment: nil))
        }
        addFacet(icon.name, part: CARPart.appIcon)
        let phone = idioms.contains(1), pad = idioms.contains(2)
        var keys: [String] = []
        if phone || !pad { keys.append("CFBundleIcons") }
        if pad { keys.append("CFBundleIcons~ipad") }
        if primary {
            files.append(("\(icon.name)60x60@2x.png", try flat.resized(width: 120, height: 120).pngData()))
            if pad { files.append(("\(icon.name)76x76@2x~ipad.png", try flat.resized(width: 152, height: 152).pngData())) }
            for key in keys {
                var dict = plist[key] as? [String: Any] ?? [:]
                var iconFiles = ["\(icon.name)60x60"]
                if key == "CFBundleIcons~ipad" { iconFiles.append("\(icon.name)76x76") }
                dict["CFBundlePrimaryIcon"] = ["CFBundleIconFiles": iconFiles, "CFBundleIconName": icon.name] as [String: Any]
                plist[key] = dict
            }
        } else {
            for key in keys {
                var dict = plist[key] as? [String: Any] ?? [:]
                var alternates = dict["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
                alternates[icon.name] = ["CFBundleIconName": icon.name]
                dict["CFBundleAlternateIcons"] = alternates
                plist[key] = dict
            }
        }
    }
}
