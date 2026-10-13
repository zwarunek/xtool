import Foundation

/// Settings that come from actool's command line.
public struct CompileOptions: Sendable {
    public var platform = "iphoneos"
    public var minimumDeploymentTarget = "26.0"
    public var targetDevices: [String] = []
    public var appIcon: String?
    public var alternateAppIcons: [String] = []
    public var includeAllAppIcons = false
    public var accentColor: String?
    public var widgetBackgroundColor: String?
    public var launchImage: String?
    public var includeLanguages: [String] = []
    public var compression: CSIPayloadCompression = .lzfse

    public init() {}
}

public enum CSIPayloadCompression: String, Sendable {
    case none, zip, lzfse
}

public struct Diagnostic: Sendable {
    public enum Kind: String, Sendable { case error, warning, notice }
    public var kind: Kind
    public var message: String
    public var item: String?

    public init(_ kind: Kind, _ message: String, item: String? = nil) {
        self.kind = kind
        self.message = message
        self.item = item
    }
}

/// The result of compiling one or more catalogs.
public struct CompileResult {
    public var car: Data?
    /// Loose files written next to Assets.car (app icon PNGs).
    public var files: [(name: String, data: Data)] = []
    public var partialInfoPlist: [String: Any] = [:]
    public var diagnostics: [Diagnostic] = []
    public var inputPaths: [String] = []
    public var renditionCount = 0
    public var facetCount = 0
}

/// Compiles parsed catalogs into CAR renditions.
public final class CatalogCompiler {
    let options: CompileOptions
    var writer = CARWriter()
    var diagnostics: [Diagnostic] = []
    var files: [(name: String, data: Data)] = []
    var plist: [String: Any] = [:]
    var usedIdentifiers: [UInt16: String] = [:]
    var identifiers: [String: UInt16] = [:]
    var localizations: Set<String> = []

    public init(options: CompileOptions) {
        self.options = options
        writer.deploymentTarget = options.minimumDeploymentTarget
        writer.platform = Self.metadataPlatform(options.platform)
    }

    static func metadataPlatform(_ platform: String) -> String {
        switch platform {
        case "iphoneos", "iphonesimulator": return "ios"
        case "macosx": return "macos"
        case "appletvos", "appletvsimulator": return "tvos"
        case "watchos", "watchsimulator": return "watchos"
        case "xros", "xrsimulator": return "xros"
        default: return platform
        }
    }

    // MARK: Idioms and devices

    static let idiomValues: [String: UInt16] = [
        "universal": 0, "iphone": 1, "ipad": 2, "tv": 3, "car": 4, "watch": 5, "ios-marketing": 6, "mac": 7, "vision": 8,
    ]

    lazy var allowedIdioms: Set<UInt16> = {
        var devices = options.targetDevices
        if devices.isEmpty {
            switch options.platform {
            case "macosx": devices = ["mac"]
            case "appletvos", "appletvsimulator": devices = ["tv"]
            case "watchos", "watchsimulator": devices = ["watch"]
            case "xros", "xrsimulator": devices = ["vision"]
            default: devices = ["iphone"]
            }
        }
        var set: Set<UInt16> = [0]
        for d in devices { if let v = Self.idiomValues[d] { set.insert(v) } }
        return set
    }()

    /// Idioms an app icon gets renditions for, in actool's order.
    var appIconIdioms: [UInt16] {
        allowedIdioms.filter { $0 != 0 }.sorted()
    }

    // MARK: Identifiers

    func identifier(for name: String) -> UInt16 {
        if let id = identifiers[name] { return id }
        var hash: UInt32 = 2_166_136_261
        for b in name.utf8 {
            hash ^= UInt32(b)
            hash = hash &* 16_777_619
        }
        var id = UInt16(truncatingIfNeeded: hash ^ (hash >> 16))
        while id == 0 || usedIdentifiers[id] != nil { id = id &+ 1 }
        usedIdentifiers[id] = name
        identifiers[name] = id
        return id
    }

    func localizationID(_ locale: String) -> UInt16 {
        localizations.insert(locale)
        if let v = writer.localizations[locale] { return v }
        var id = identifier(for: "\u{0}locale:" + locale)
        if id == 0 { id = 1 }
        writer.localizations[locale] = id
        return id
    }

    // MARK: Driver

    public func compile(_ catalogs: [AssetCatalog], icons: [IconComposerIcon] = []) -> CompileResult {
        var result = CompileResult()
        for icon in icons { result.inputPaths += icon.inputPaths }
        var assets: [Asset] = []
        for c in catalogs {
            assets += c.assets
            result.inputPaths += c.inputPaths
        }
        // Assign identifiers in name order so output doesn't depend on folder layout.
        for a in assets.sorted(by: { $0.name < $1.name }) { _ = identifier(for: a.name) }

        let primaryIcons = Set([options.appIcon].compactMap { $0 })
        let alternates = Set(options.alternateAppIcons)
        for asset in assets {
            do {
                switch asset.kind {
                case .imageSet: try compileImageSet(asset)
                case .colorSet: try compileColorSet(asset)
                case .dataSet: try compileDataSet(asset)
                case .appIconSet:
                    let isPrimary = primaryIcons.contains(asset.name)
                    let isAlternate = alternates.contains(asset.name) || (options.includeAllAppIcons && !isPrimary)
                    if isPrimary || isAlternate { try compileAppIconSet(asset, primary: isPrimary) }
                case .symbolSet: try compileSymbolSet(asset)
                case .launchImage, .brandAssets, .imageStack, .imageStackLayer:
                    if allowedIdioms.contains(3) {
                        diagnostics.append(Diagnostic(.warning, "\(asset.kind.rawValue) is not supported by this actool; skipped", item: asset.name))
                    }
                default:
                    diagnostics.append(Diagnostic(.warning, "\(asset.kind.rawValue) is not supported by this actool; skipped", item: asset.name))
                }
            } catch {
                diagnostics.append(Diagnostic(.error, "\(error)", item: asset.name))
            }
        }
        for icon in icons where primaryIcons.contains(icon.name) || alternates.contains(icon.name) || options.includeAllAppIcons {
            guard !assets.contains(where: { $0.kind == .appIconSet && $0.name == icon.name }) else { continue }
            do {
                try compileIconComposerIcon(icon, primary: primaryIcons.contains(icon.name))
            } catch {
                diagnostics.append(Diagnostic(.error, "\(error)", item: icon.name))
            }
        }
        for name in primaryIcons.union(alternates) where !assets.contains(where: { $0.kind == .appIconSet && $0.name == name }) && !icons.contains(where: { $0.name == name }) {
            diagnostics.append(Diagnostic(.error, "None of the input catalogs contained a matching stickers icon set or app icon set named  \"\(name)\"."))
        }
        if let accent = options.accentColor {
            if assets.contains(where: { $0.kind == .colorSet && $0.name == accent }) {
                plist["NSAccentColorName"] = accent
            } else {
                diagnostics.append(Diagnostic(.warning, "Accent color '\(accent)' is not present in any asset catalogs."))
            }
        }
        if let widget = options.widgetBackgroundColor {
            if assets.contains(where: { $0.kind == .colorSet && $0.name == widget }) {
                plist["NSWidgetBackgroundColorName"] = widget
            } else {
                diagnostics.append(Diagnostic(.warning, "Widget background color '\(widget)' is not present in any asset catalogs."))
            }
        }
        if !localizations.isEmpty {
            plist["CFBundleLocalizations"] = localizations.sorted()
        }

        var seen = Set<[UInt16]>()
        writer.renditions = writer.renditions.filter { r in
            seen.insert(CARAttribute.allCases.map { r.key[$0] ?? 0 }).inserted
        }
        if !writer.renditions.isEmpty {
            result.car = writer.serialize()
        }
        result.renditionCount = writer.renditions.count
        result.facetCount = writer.facets.count
        result.files = files
        result.partialInfoPlist = plist
        result.diagnostics = diagnostics
        return result
    }

    func addFacet(_ name: String, part: UInt16, extra: [CARAttribute: UInt16] = [:]) {
        var attrs: [CARAttribute: UInt16] = [.element: CARElement.named, .part: part, .identifier: identifier(for: name)]
        for (k, v) in extra { attrs[k] = v }
        writer.facets.append(CARWriter.Facet(name: name, attributes: attrs))
    }

    func baseKey(_ name: String, part: UInt16) -> [CARAttribute: UInt16] {
        [.element: CARElement.named, .part: part, .identifier: identifier(for: name)]
    }

    var payloadCompression: CSIPayload.Compression {
        switch options.compression {
        case .none: return .none
        case .zip: return .zip
        case .lzfse: return .lzfse
        }
    }

    // MARK: Variant attributes shared by images, colors and data

    struct Variant {
        var idiom: UInt16 = 0
        var appearance: UInt16 = 0
        var locale: String?
        var horizontalSizeClass: UInt16 = 0
        var verticalSizeClass: UInt16 = 0
        var subtype: UInt16 = 0
        var memoryClass: UInt16 = 0
        var graphicsClass: UInt16 = 0
        var displayGamut: UInt16 = 0
    }

    static let appearanceNames: [UInt16: String] = [
        0: "UIAppearanceAny", 1: "UIAppearanceDark", 2: "UIAppearanceHighContrastAny", 3: "UIAppearanceHighContrastDark",
        4: "UIAppearanceLight", 5: "UIAppearanceHighContrastLight", 10: "ISAppearanceTintable",
    ]

    func variant(of item: [String: JSONValue], assetName: String) -> Variant? {
        var v = Variant()
        let idiomName = item["idiom"]?.string ?? "universal"
        guard let idiom = Self.idiomValues[idiomName] else { return nil }
        v.idiom = idiom
        var dark = false, light = false, highContrast = false, tinted = false
        for a in item["appearances"]?.array ?? [] {
            let kind = a["appearance"]?.string, value = a["value"]?.string
            if kind == "luminosity" {
                if value == "dark" { dark = true }
                if value == "light" { light = true }
                if value == "tinted" { tinted = true }
            } else if kind == "contrast", value == "high" {
                highContrast = true
            }
        }
        if tinted {
            v.appearance = 10
        } else if highContrast {
            v.appearance = dark ? 3 : (light ? 5 : 2)
        } else {
            v.appearance = dark ? 1 : (light ? 4 : 0)
        }
        if v.appearance != 0, let name = Self.appearanceNames[v.appearance] {
            writer.appearances[name] = v.appearance
        }
        if let locale = item["locale"]?.string {
            if !options.includeLanguages.isEmpty && !options.includeLanguages.contains(locale) { return nil }
            v.locale = locale
        }
        v.horizontalSizeClass = Self.sizeClass((item["width-class"] ?? item["widthClass"])?.string)
        v.verticalSizeClass = Self.sizeClass((item["height-class"] ?? item["heightClass"])?.string)
        if let s = item["subtype"]?.string {
            switch s {
            case "retina4": v.subtype = 568
            case "1792h": v.subtype = 1792
            case "2436h": v.subtype = 2436
            case "2688h": v.subtype = 2688
            default: v.subtype = UInt16(s.filter(\.isNumber)) ?? 0
            }
        }
        if let gamut = item["display-gamut"]?.string {
            v.displayGamut = gamut == "display-P3" ? 1 : 0
        }
        if let mem = item["memory"]?.string {
            v.memoryClass = UInt16(mem.filter(\.isNumber)) ?? 0
        }
        return v
    }

    static func sizeClass(_ s: String?) -> UInt16 {
        switch s {
        case "compact": return 1
        case "regular": return 2
        default: return 0
        }
    }

    func key(_ name: String, part: UInt16, variant v: Variant, scale: UInt16) -> [CARAttribute: UInt16] {
        var k = baseKey(name, part: part)
        k[.idiom] = v.idiom
        k[.appearance] = v.appearance
        k[.scale] = scale
        if let locale = v.locale { k[.localization] = localizationID(locale) }
        if v.horizontalSizeClass != 0 { k[.horizontalSizeClass] = v.horizontalSizeClass }
        if v.verticalSizeClass != 0 { k[.verticalSizeClass] = v.verticalSizeClass }
        if v.subtype != 0 { k[.subtype] = v.subtype }
        if v.displayGamut != 0 { k[.displayGamut] = v.displayGamut }
        if v.memoryClass != 0 { k[.memoryClass] = v.memoryClass }
        return k
    }

    // MARK: Colors

    static let colorSpaces: [String: UInt32] = [
        "srgb": 1, "gray-gamma-22": 2, "display-p3": 3, "extended-srgb": 4, "extended-linear-srgb": 5, "extended-gray": 6,
        "extended-range-srgb": 4,
    ]

    /// Parses a component the way Xcode does: "0xNN" and plain integers are 0-255, decimals are single precision.
    static func component(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if case .number(let d, let raw) = value {
            if !raw.contains(".") && !raw.contains("e") && !raw.contains("E") && d > 1 { return d / 255 }
            return Double(Float(d))
        }
        guard let s = value.string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.lowercased().hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) { return Double(v) / 255 }
        if !s.contains("."), !s.lowercased().contains("e"), let v = Int(s) {
            return v > 1 ? Double(v) / 255 : Double(v)
        }
        if let f = Float(s) { return Double(f) }
        return nil
    }

    func compileColorSet(_ asset: Asset) throws {
        var produced = false
        for item in asset.contents["colors"]?.array ?? [] {
            guard let obj = item.object, let v = variant(of: obj, assetName: asset.name), allowedIdioms.contains(v.idiom) else { continue }
            guard let color = obj["color"]?.object else { continue }
            if color["reference"] != nil {
                diagnostics.append(Diagnostic(.warning, "system color references are not supported by this actool; skipped", item: asset.name))
                continue
            }
            let spaceName = color["color-space"]?.string ?? "srgb"
            guard let space = Self.colorSpaces[spaceName] else {
                diagnostics.append(Diagnostic(.warning, "unsupported color space \(spaceName)", item: asset.name))
                continue
            }
            let comps = color["components"]?.object ?? [:]
            var values: [Double]
            if space == 2 || space == 6 {
                values = [Self.component(comps["white"]) ?? 0, Self.component(comps["alpha"]) ?? 1]
            } else {
                values = [Self.component(comps["red"]) ?? 0, Self.component(comps["green"]) ?? 0, Self.component(comps["blue"]) ?? 0, Self.component(comps["alpha"]) ?? 1]
            }
            var r = CSIRendition(key: key(asset.name, part: CARPart.color, variant: v, scale: 1), layout: CSILayout.color, name: asset.name, payload: CSIPayload.color(colorSpaceID: space, components: values))
            r.info = [CSIInfoBuilder.composition(opacity: 0), CSIInfoBuilder.bitmapInfo()]
            writer.renditions.append(r)
            produced = true
        }
        if produced { addFacet(asset.name, part: CARPart.color) }
    }

    // MARK: Data

    func compileDataSet(_ asset: Asset) throws {
        var produced = false
        for item in asset.contents["data"]?.array ?? [] {
            guard let obj = item.object, let file = obj["filename"]?.string,
                  let v = variant(of: obj, assetName: asset.name), allowedIdioms.contains(v.idiom) else { continue }
            let url = asset.directory.appendingPathComponent(file)
            guard let bytes = FileManager.default.contents(atPath: url.path) else {
                diagnostics.append(Diagnostic(.error, "missing data file \(file)", item: asset.name))
                continue
            }
            let uti = obj["universal-type-identifier"]?.string
            var r = CSIRendition(key: key(asset.name, part: CARPart.data, variant: v, scale: 1), layout: CSILayout.rawData, name: uti != nil ? "CoreStructuredImage" : file, payload: CSIPayload.raw(bytes, compress: false))
            r.pixelFormat = fourCC("DATA")
            r.scaleFactor = 100
            r.info = [CSIInfoBuilder.composition(opacity: 1)]
            if let uti { r.info.append(CSIInfoBuilder.uti(uti)) }
            r.info.append(CSIInfoBuilder.bitmapInfo())
            writer.renditions.append(r)
            produced = true
        }
        if produced { addFacet(asset.name, part: CARPart.data) }
    }

    // MARK: Images

    /// CSI flag bits: template rendering mode lives in bits 3-4, vector-sourced rasters set bit 2, preserved vectors set bit 8.
    static func imageFlags(intent: UInt32, fromVector: Bool, preservesVector: Bool) -> UInt32 {
        (intent << 3) | (fromVector ? 0x4 : 0) | (preservesVector ? 0x100 : 0)
    }

    struct ResizeSpec {
        var layout: UInt16
        var crop: [(src: Int, len: Int)]  // horizontal pieces kept, in source pixels
        var cropV: [(src: Int, len: Int)]
        var slicesX: [Int]  // widths of horizontal pieces in the cropped image
        var slicesY: [Int]  // heights of vertical pieces (top to bottom)
    }

    func resizeSpec(_ resizing: [String: JSONValue], width: Int, height: Int) -> ResizeSpec? {
        guard let mode = resizing["mode"]?.string else { return nil }
        let caps = resizing["cap-insets"]?.object ?? [:]
        let center = resizing["center"]?.object ?? [:]
        let tile = center["mode"]?.string == "tile"
        func cap(_ k: String) -> Int { Int(caps[k]?.double ?? 0) }
        let left = cap("left"), right = cap("right"), top = cap("top"), bottom = cap("bottom")
        let cw = max(1, Int(center["width"]?.double ?? 1))
        let ch = max(1, Int(center["height"]?.double ?? 1))
        let horizontal = mode == "3-part-horizontal" || mode == "9-part"
        let vertical = mode == "3-part-vertical" || mode == "9-part"
        var spec = ResizeSpec(layout: CSILayout.onePartScale, crop: [(0, width)], cropV: [(0, height)], slicesX: [width], slicesY: [height])
        if horizontal {
            let c = min(cw, max(0, width - left - right))
            spec.crop = [(0, left), (left, c), (width - right, right)]
            spec.slicesX = [left, c, right]
        }
        if vertical {
            let c = min(ch, max(0, height - top - bottom))
            spec.cropV = [(0, top), (top, c), (height - bottom, bottom)]
            spec.slicesY = [top, c, bottom]
        }
        switch mode {
        case "3-part-horizontal": spec.layout = tile ? CSILayout.threePartHorizontalTile : CSILayout.threePartHorizontalScale
        case "3-part-vertical": spec.layout = tile ? CSILayout.threePartVerticalTile : CSILayout.threePartVerticalScale
        case "9-part": spec.layout = tile ? CSILayout.ninePartTile : CSILayout.ninePartScale
        default: return nil
        }
        return spec
    }

    func crop(_ bitmap: Bitmap, _ spec: ResizeSpec) -> Bitmap {
        let w = spec.crop.reduce(0) { $0 + $1.len }
        let h = spec.cropV.reduce(0) { $0 + $1.len }
        var out = Bitmap(width: w, height: h)
        var dy = 0
        for (sy0, hl) in spec.cropV {
            for y in 0..<hl {
                var dx = 0
                for (sx0, wl) in spec.crop {
                    for x in 0..<wl {
                        let s = ((sy0 + y) * bitmap.width + sx0 + x) * 4
                        let d = ((dy + y) * w + dx + x) * 4
                        out.pixels[d] = bitmap.pixels[s]
                        out.pixels[d + 1] = bitmap.pixels[s + 1]
                        out.pixels[d + 2] = bitmap.pixels[s + 2]
                        out.pixels[d + 3] = bitmap.pixels[s + 3]
                    }
                    dx += wl
                }
            }
            dy += hl
        }
        return out
    }

    /// Slice rectangles in CoreUI's bottom-left origin coordinates.
    func sliceRects(_ spec: ResizeSpec?, width: Int, height: Int) -> [(x: UInt32, y: UInt32, w: UInt32, h: UInt32)] {
        guard let spec else { return [(0, 0, UInt32(width), UInt32(height))] }
        var rects: [(UInt32, UInt32, UInt32, UInt32)] = []
        var top = 0
        for hgt in spec.slicesY {
            let y = height - top - hgt
            var x = 0
            for wid in spec.slicesX {
                rects.append((UInt32(x), UInt32(y), UInt32(wid), UInt32(hgt)))
                x += wid
            }
            top += hgt
        }
        return rects
    }

    /// `content` is the drawn area of a vector raster whose pixel size was rounded up; its slice covers just that area.
    func rasterRendition(_ bitmap: Bitmap, key: [CARAttribute: UInt16], name: String, scale: Int, flags: UInt32,
                         resizing: [String: JSONValue]?, alignment: [String: JSONValue]?, content: (width: Int, height: Int)? = nil) -> CSIRendition {
        var bmp = bitmap
        var spec: ResizeSpec?
        if let resizing, let s = resizeSpec(resizing, width: bitmap.width, height: bitmap.height) {
            spec = s
            bmp = crop(bitmap, s)
        }
        let gray = bmp.isGrayscale
        let raw: Data = gray ? Data(bmp.grayAlphaPixels) : Data(bmp.pixels)
        var r = CSIRendition(key: key, layout: spec?.layout ?? CSILayout.onePartScale, name: name, payload: CSIPayload.pixels(raw, compression: payloadCompression))
        r.flags = flags
        r.width = UInt32(bmp.width)
        r.height = UInt32(bmp.height)
        r.scaleFactor = UInt32(scale * 100)
        r.pixelFormat = fourCC(gray ? "GA8 " : "ARGB")
        r.colorSpaceID = gray ? 2 : 1
        var topLeft: (UInt32, UInt32) = (0, 0), bottomRight: (UInt32, UInt32) = (0, 0)
        var contentW = UInt32(bmp.width), contentH = UInt32(bmp.height)
        if let alignment {
            let t = UInt32(max(0, alignment["top"]?.double ?? 0)), l = UInt32(max(0, alignment["left"]?.double ?? 0))
            let b = UInt32(max(0, alignment["bottom"]?.double ?? 0)), rt = UInt32(max(0, alignment["right"]?.double ?? 0))
            topLeft = (l, t)
            bottomRight = (rt, b)
            contentW = contentW > l + rt ? contentW - l - rt : contentW
            contentH = contentH > t + b ? contentH - t - b : contentH
        }
        var slices = sliceRects(spec, width: bmp.width, height: bmp.height)
        if spec == nil, let content, content.width <= bmp.width, content.height <= bmp.height {
            slices = [(0, UInt32(bmp.height - content.height), UInt32(content.width), UInt32(content.height))]
        }
        r.info = [
            CSIInfoBuilder.slices(slices),
            CSIInfoBuilder.metrics(width: contentW, height: contentH, topRight: topLeft, bottomLeft: bottomRight),
            CSIInfoBuilder.composition(opacity: 1),
            CSIInfoBuilder.bitmapInfo(),
            CSIInfoBuilder.bytesPerRow(UInt32(bmp.width * (gray ? 2 : 4))),
        ]
        return r
    }

    enum SourceKind { case raster, jpeg, svg, pdf, unsupported }

    static func sourceKind(_ file: String) -> SourceKind {
        switch (file as NSString).pathExtension.lowercased() {
        case "png", "gif", "bmp", "tga", "tif", "tiff": return .raster
        case "jpg", "jpeg": return .jpeg
        case "svg": return .svg
        case "pdf": return .pdf
        default: return .unsupported
        }
    }

    struct VectorSource {
        var data: Data
        var kind: SourceKind
        var width: Double
        var height: Double

        func render(width: Int, height: Int, scale: Double, name: String) throws -> Bitmap {
            switch kind {
            case .svg: return try Bitmap.renderSVG(data, width: width, height: height, scale: scale, name: name)
            case .pdf: return try PDFDocument(data: data).renderFirstPage(width: width, height: height)
            default: throw Bitmap.Error.decode(name)
            }
        }
    }

    func loadVector(_ url: URL, kind: SourceKind) throws -> VectorSource {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw Bitmap.Error.decode(url.lastPathComponent) }
        switch kind {
        case .svg:
            guard let size = Bitmap.svgSize(data) else { throw Bitmap.Error.svg(url.lastPathComponent) }
            return VectorSource(data: data, kind: .svg, width: size.width, height: size.height)
        default:
            let doc = try PDFDocument(data: data)
            let size = try doc.firstPageSize()
            return VectorSource(data: data, kind: .pdf, width: size.width, height: size.height)
        }
    }

    func compileImageSet(_ asset: Asset) throws {
        let props = asset.contents["properties"]?.object ?? [:]
        let intent: UInt32
        switch props["template-rendering-intent"]?.string {
        case "template": intent = 1
        case "original": intent = 0
        default: intent = 2
        }
        let preserves = props["preserves-vector-representation"]?.bool ?? false
        var produced = false
        let images = (asset.contents["images"]?.array ?? []).compactMap(\.object)

        struct Entry {
            var obj: [String: JSONValue]
            var variant: Variant
            var file: String
            var scale: Int?
        }
        var entries: [Entry] = []
        for obj in images {
            guard let file = obj["filename"]?.string, let v = variant(of: obj, assetName: asset.name), allowedIdioms.contains(v.idiom) else { continue }
            let scale = obj["scale"]?.string.flatMap { Int($0.replacingOccurrences(of: "x", with: "")) }
            entries.append(Entry(obj: obj, variant: v, file: file, scale: scale))
        }

        func variantKey(_ v: Variant) -> String {
            "\(v.idiom)-\(v.appearance)-\(v.locale ?? "")-\(v.horizontalSizeClass)-\(v.verticalSizeClass)-\(v.subtype)-\(v.memoryClass)-\(v.displayGamut)"
        }
        // Scales that have a raster for each variant; a vector only fills scales without one.
        var rasterScales: [String: Set<Int>] = [:]
        for e in entries where [.raster, .jpeg].contains(Self.sourceKind(e.file)) {
            rasterScales[variantKey(e.variant), default: []].insert(e.scale ?? 1)
        }

        for e in entries {
            let url = asset.directory.appendingPathComponent(e.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                diagnostics.append(Diagnostic(.warning, "The image set \"\(asset.name)\" references a file \"\(e.file)\", but that file does not exist.", item: asset.name))
                continue
            }
            let kind = Self.sourceKind(e.file)
            let resizing = e.obj["resizing"]?.object
            let alignment = e.obj["alignment-insets"]?.object
            switch kind {
            case .raster:
                guard let data = FileManager.default.contents(atPath: url.path) else { continue }
                var bitmap = try Bitmap.decode(data, name: e.file)
                if PNGInfo.isIndexedWithTransparency(data) { bitmap.premultiplyAgain() }
                let scale = e.scale ?? 1
                let k = key(asset.name, part: CARPart.image, variant: e.variant, scale: UInt16(scale))
                writer.renditions.append(rasterRendition(bitmap, key: k, name: e.file, scale: scale,
                                                         flags: Self.imageFlags(intent: intent, fromVector: false, preservesVector: preserves),
                                                         resizing: resizing, alignment: alignment))
                produced = true
            case .jpeg:
                guard let data = FileManager.default.contents(atPath: url.path) else { continue }
                let bitmap = try Bitmap.decode(data, name: e.file)
                let scale = e.scale ?? 1
                var r = CSIRendition(key: key(asset.name, part: CARPart.image, variant: e.variant, scale: UInt16(scale)), layout: CSILayout.onePartScale, name: e.file, payload: CSIPayload.raw(data, compress: false))
                r.flags = Self.imageFlags(intent: intent, fromVector: false, preservesVector: preserves)
                r.scaleFactor = UInt32(scale * 100)
                r.pixelFormat = fourCC("JPEG")
                r.info = [
                    CSIInfoBuilder.slices([(0, 0, UInt32(bitmap.width), UInt32(bitmap.height))]),
                    CSIInfoBuilder.metrics(width: UInt32(bitmap.width), height: UInt32(bitmap.height)),
                    CSIInfoBuilder.composition(opacity: 1),
                    CSIInfoBuilder.bitmapInfo(),
                ]
                writer.renditions.append(r)
                produced = true
            case .svg, .pdf:
                let source = try loadVector(url, kind: kind)
                let slotScale = Double(e.scale ?? 1)
                let pointW = source.width / slotScale, pointH = source.height / slotScale
                let have = rasterScales[variantKey(e.variant)] ?? []
                for s in 1...3 where !have.contains(s) {
                    // actool sizes SVG rasters up and PDF rasters to the nearest pixel.
                    let rule: FloatingPointRoundingRule = kind == .svg ? .up : .toNearestOrAwayFromZero
                    let pw = max(1, Int((pointW * Double(s) - (kind == .svg ? 1e-3 : 0)).rounded(rule)))
                    let ph = max(1, Int((pointH * Double(s) - (kind == .svg ? 1e-3 : 0)).rounded(rule)))
                    let bitmap = try source.render(width: pw, height: ph, scale: Double(s) / slotScale, name: e.file)
                    let k = key(asset.name, part: CARPart.image, variant: e.variant, scale: UInt16(s))
                    let content = kind == .svg ? (max(1, Int((pointW * Double(s)).rounded())), max(1, Int((pointH * Double(s)).rounded()))) : nil
                    writer.renditions.append(rasterRendition(bitmap, key: k, name: e.file, scale: s,
                                                             flags: Self.imageFlags(intent: intent, fromVector: true, preservesVector: preserves),
                                                             resizing: resizing, alignment: alignment, content: content))
                }
                var vk = key(asset.name, part: preserves ? CARPart.vector : CARPart.image, variant: e.variant, scale: preserves ? 1 : 0)
                if !preserves { vk[.scale] = 0 }
                var r = CSIRendition(key: vk, layout: CSILayout.vector, name: e.file, payload: CSIPayload.raw(source.data, compress: true))
                r.flags = 0x4
                r.pixelFormat = fourCC(kind == .svg ? "SVG " : "PDF ")
                r.info = [CSIInfoBuilder.composition(opacity: 1), CSIInfoBuilder.bitmapInfo()]
                writer.renditions.append(r)
                produced = true
            case .unsupported:
                diagnostics.append(Diagnostic(.warning, "unsupported image type \(e.file)", item: asset.name))
            }
        }
        if produced { addFacet(asset.name, part: CARPart.image) }
    }
}
