import Foundation

/// Rendition key attributes (CoreUI's `kCRTheme*Name` identifiers).
public enum CARAttribute: UInt16, CaseIterable, Comparable, Sendable {
    case element = 1
    case part = 2
    case size = 3
    case direction = 4
    case value = 6
    case appearance = 7
    case dimension1 = 8
    case dimension2 = 9
    case state = 10
    case layer = 11
    case scale = 12
    case localization = 13
    case presentationState = 14
    case idiom = 15
    case subtype = 16
    case identifier = 17
    case previousValue = 18
    case previousState = 19
    case horizontalSizeClass = 20
    case verticalSizeClass = 21
    case memoryClass = 22
    case graphicsClass = 23
    case displayGamut = 24
    case deploymentTarget = 25
    case glyphWeight = 26
    case glyphSize = 27

    public static func < (a: CARAttribute, b: CARAttribute) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .element: return "element"
        case .part: return "part"
        case .size: return "size"
        case .direction: return "direction"
        case .value: return "value"
        case .appearance: return "appearance"
        case .dimension1: return "dimension1"
        case .dimension2: return "dimension2"
        case .state: return "state"
        case .layer: return "layer"
        case .scale: return "scale"
        case .localization: return "localization"
        case .presentationState: return "presentationState"
        case .idiom: return "idiom"
        case .subtype: return "subtype"
        case .identifier: return "identifier"
        case .previousValue: return "previousValue"
        case .previousState: return "previousState"
        case .horizontalSizeClass: return "horizontalSizeClass"
        case .verticalSizeClass: return "verticalSizeClass"
        case .memoryClass: return "memoryClass"
        case .graphicsClass: return "graphicsClass"
        case .displayGamut: return "displayGamut"
        case .deploymentTarget: return "deploymentTarget"
        case .glyphWeight: return "glyphWeight"
        case .glyphSize: return "glyphSize"
        }
    }

    /// Key order used by actool: leading attributes, optional ones, then identifier/element/part.
    static let leading: [CARAttribute] = [.appearance, .localization, .scale, .idiom, .subtype]
    static let optionalOrder: [CARAttribute] = [
        .glyphWeight, .glyphSize, .dimension2, .dimension1, .deploymentTarget, .horizontalSizeClass, .verticalSizeClass,
        .displayGamut, .memoryClass, .graphicsClass,
        .size, .direction, .value, .state, .layer, .presentationState, .previousValue, .previousState,
    ]
    static let trailing: [CARAttribute] = [.identifier, .element, .part]
}

/// Values for the `element` and `part` attributes.
enum CARElement {
    static let named: UInt16 = 85
    static let packedImage: UInt16 = 9
}

enum CARPart {
    static let image: UInt16 = 181
    static let color: UInt16 = 217
    static let multisizeImageSet: UInt16 = 218
    static let appIcon: UInt16 = 220
    static let vector: UInt16 = 42
    static let symbol: UInt16 = 59
    static let data: UInt16 = 181
}

/// CSI rendition layouts.
enum CSILayout {
    static let vector: UInt16 = 9
    static let onePartFixedSize: UInt16 = 10
    static let onePartTile: UInt16 = 11
    static let onePartScale: UInt16 = 12
    static let threePartHorizontalTile: UInt16 = 20
    static let threePartHorizontalScale: UInt16 = 21
    static let threePartVerticalTile: UInt16 = 23
    static let threePartVerticalScale: UInt16 = 24
    static let ninePartTile: UInt16 = 30
    static let ninePartScale: UInt16 = 31
    static let rawData: UInt16 = 1000
    static let color: UInt16 = 1009
    static let multisizeImageSet: UInt16 = 1010
    static let symbol: UInt16 = 1017
}

/// CSI info entry types (TLVs between the rendition header and its payload).
enum CSIInfo {
    static let slices: UInt32 = 1001
    static let metrics: UInt32 = 1003
    static let composition: UInt32 = 1004
    static let uti: UInt32 = 1005
    static let bitmapInfo: UInt32 = 1006
    static let bytesPerRow: UInt32 = 1007
    static let reference: UInt32 = 1010
    static let glyphMetrics: UInt32 = 1018
    static let glyphInfo: UInt32 = 1019
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

func fourCCString(_ v: UInt32) -> String {
    if v == 0 { return "" }
    let bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    return String(decoding: bytes, as: UTF8.self)
}

/// One rendition: a CSI header, info TLVs and a payload.
struct CSIRendition {
    var key: [CARAttribute: UInt16]
    var flags: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var scaleFactor: UInt32 = 0  // scale * 100
    var pixelFormat: UInt32 = 0  // four-character code, e.g. fourCC("ARGB")
    var colorSpaceID: UInt32 = 0
    var layout: UInt16
    var name: String
    var info: [(type: UInt32, payload: Data)] = []
    var payload: Data

    func serialize() -> Data {
        var infoBytes = ByteWriter()
        for entry in info {
            infoBytes.u32le(entry.type)
            infoBytes.u32le(UInt32(entry.payload.count))
            infoBytes.bytes(entry.payload)
        }
        var w = ByteWriter(capacity: 184 + infoBytes.count + payload.count)
        w.tag("ISTC")
        w.u32le(1)
        w.u32le(flags)
        w.u32le(width)
        w.u32le(height)
        w.u32le(scaleFactor)
        w.u32le(pixelFormat)
        w.u32le(colorSpaceID & 0xf)
        w.u32le(0)  // modification date
        w.u16le(layout)
        w.u16le(0)
        w.fixedString(name, length: 128)
        w.u32le(UInt32(infoBytes.count))
        w.u32le(1)  // bitmap count
        w.u32le(0)
        w.u32le(UInt32(payload.count))
        w.bytes(infoBytes.data)
        w.bytes(payload)
        return w.data
    }
}

/// Builders for the common info TLVs.
enum CSIInfoBuilder {
    static func slices(_ rects: [(x: UInt32, y: UInt32, w: UInt32, h: UInt32)]) -> (UInt32, Data) {
        var w = ByteWriter()
        w.u32le(UInt32(rects.count))
        for r in rects {
            w.u32le(r.x)
            w.u32le(r.y)
            w.u32le(r.w)
            w.u32le(r.h)
        }
        return (CSIInfo.slices, w.data)
    }

    static func metrics(width: UInt32, height: UInt32, topRight: (UInt32, UInt32) = (0, 0), bottomLeft: (UInt32, UInt32) = (0, 0)) -> (UInt32, Data) {
        var w = ByteWriter()
        w.u32le(1)
        w.u32le(topRight.0)
        w.u32le(topRight.1)
        w.u32le(bottomLeft.0)
        w.u32le(bottomLeft.1)
        w.u32le(width)
        w.u32le(height)
        return (CSIInfo.metrics, w.data)
    }

    static func composition(opacity: Float, blendMode: UInt32 = 0) -> (UInt32, Data) {
        var w = ByteWriter()
        w.u32le(blendMode)
        w.f32le(opacity)
        return (CSIInfo.composition, w.data)
    }

    static func bitmapInfo(exifOrientation: UInt32 = 1) -> (UInt32, Data) {
        var w = ByteWriter()
        w.u32le(exifOrientation)
        return (CSIInfo.bitmapInfo, w.data)
    }

    static func bytesPerRow(_ value: UInt32) -> (UInt32, Data) {
        var w = ByteWriter()
        w.u32le(value)
        return (CSIInfo.bytesPerRow, w.data)
    }

    static func uti(_ value: String) -> (UInt32, Data) {
        var w = ByteWriter()
        var utf8 = Array(value.utf8)
        utf8.append(0)
        while utf8.count % 4 != 0 { utf8.append(0) }
        w.u32le(UInt32(utf8.count))
        w.bytes(utf8)
        return (CSIInfo.uti, w.data)
    }
}

/// Builds the payloads that follow the CSI header.
enum CSIPayload {
    enum Compression: UInt32 {
        case none = 0
        case rle = 1
        case zip = 2
        case lzvn = 3
        case lzfse = 4
    }

    /// A pixel payload ("MLEC"): header plus the pixel bytes, optionally compressed.
    static func pixels(_ raw: Data, compression: Compression) -> Data {
        let body: Data
        var used = compression
        switch compression {
        case .lzfse:
            if let c = LZFSE.encode(raw), c.count < raw.count {
                body = c
            } else {
                body = raw
                used = .none
            }
        case .zip:
            if let c = Gzip.compress(raw) {
                body = c
            } else {
                body = raw
                used = .none
            }
        default:
            body = raw
            used = .none
        }
        var w = ByteWriter(capacity: body.count + 16)
        w.tag("MLEC")
        w.u32le(0)
        w.u32le(used.rawValue)
        w.u32le(UInt32(body.count))
        w.bytes(body)
        return w.data
    }

    /// A raw data payload ("DWAR"); with `compress`, the bytes are LZFSE compressed as actool does for SVG and data.
    static func raw(_ data: Data, compress: Bool) -> Data {
        var body = data
        var flag: UInt32 = 0
        if compress, let c = LZFSE.encode(data) {
            body = c
            flag = 1
        }
        var w = ByteWriter(capacity: body.count + 12)
        w.tag("DWAR")
        w.u32le(flag)
        w.u32le(UInt32(body.count))
        w.bytes(body)
        return w.data
    }

    /// A color payload ("RLOC"): color space id and components as doubles.
    static func color(colorSpaceID: UInt32, components: [Double]) -> Data {
        var w = ByteWriter()
        w.tag("RLOC")
        w.u32le(1)
        w.u32le(colorSpaceID)
        w.u32le(UInt32(components.count))
        for c in components { w.f64le(c) }
        return w.data
    }

    /// A multisize image set payload ("SISM"): the icon sizes and the dimension2 index of each.
    static func multisize(_ entries: [(width: UInt32, height: UInt32, index: UInt16, idiom: UInt16)]) -> Data {
        var w = ByteWriter()
        w.tag("SISM")
        w.u32le(1)
        w.u32le(UInt32(entries.count))
        for e in entries {
            w.u32le(e.width)
            w.u32le(e.height)
            w.u16le(e.index)
            w.u16le(e.idiom)
        }
        return w.data
    }
}

/// Assembles a CAR file: CARHEADER, EXTENDED_METADATA, KEYFORMAT, APPEARANCEKEYS, FACETKEYS, RENDITIONS.
struct CARWriter {
    struct Facet {
        var name: String
        var attributes: [CARAttribute: UInt16]
    }

    var facets: [Facet] = []
    var renditions: [CSIRendition] = []
    var appearances: [String: UInt16] = ["UIAppearanceAny": 0]
    var localizations: [String: UInt16] = [:]
    var deploymentTarget = "26.0"
    var platform = "ios"
    var authoringTool = "xtool actool (ActoolKit)"
    var keySemantics: UInt32 = 2

    func keyFormat() -> [CARAttribute] {
        var used = Set<CARAttribute>()
        for r in renditions {
            for (k, v) in r.key where v != 0 { used.insert(k) }
        }
        var format = CARAttribute.leading
        for a in CARAttribute.optionalOrder where used.contains(a) { format.append(a) }
        format += CARAttribute.trailing
        return format
    }

    func serialize() -> Data {
        let bom = BOMWriter()
        let format = keyFormat()

        var header = ByteWriter()
        header.tag("RATC")
        header.u32le(975)  // CoreUI version of the producing toolchain
        header.u32le(17)  // storage version
        header.u32le(0)  // storage timestamp
        header.u32le(UInt32(renditions.count))
        header.fixedString("@(#)PROGRAM:CoreUI  PROJECT:CoreUI-975", length: 128)
        header.fixedString(authoringTool, length: 256)
        header.zeros(16)  // uuid
        header.u32le(0)  // associated checksum
        header.u32le(2)  // schema version
        header.u32le(1)  // color space id
        header.u32le(keySemantics)
        let headerBlock = bom.addBlock(header.data)

        // Renditions first: their blocks come right after the header, as in actool's files.
        let keyed: [(Data, Data)] = renditions.map { r in
            var k = ByteWriter()
            for a in format { k.u16le(r.key[a] ?? 0) }
            return (k.data, r.serialize())
        }.sorted { Data.bomLess($0.0, $1.0) }
        bom.addVariable("CARHEADER", block: headerBlock)
        bom.addTree("RENDITIONS", entries: keyed.map { (key: $0.0, value: $0.1) }, leafPaddingPerEntry: format.count * 2)

        let facetEntries: [(Data, Data)] = facets.map { f in
            var v = ByteWriter()
            v.u16le(0)  // hot spot x
            v.u16le(0)  // hot spot y
            let attrs = f.attributes.sorted { $0.key < $1.key }
            v.u16le(UInt16(attrs.count))
            for (a, value) in attrs {
                v.u16le(a.rawValue)
                v.u16le(value)
            }
            return (Data(f.name.utf8), v.data)
        }.sorted { Data.bomLess($0.0, $1.0) }
        bom.addTree("FACETKEYS", entries: facetEntries.map { (key: $0.0, value: $0.1) })

        let appearanceEntries = appearances.map { name, value -> (Data, Data) in
            var v = ByteWriter()
            v.u16le(value)
            return (Data(name.utf8), v.data)
        }.sorted { Data.bomLess($0.0, $1.0) }
        bom.addTree("APPEARANCEKEYS", entries: appearanceEntries.map { (key: $0.0, value: $0.1) })

        if !localizations.isEmpty {
            let entries = localizations.map { name, value -> (Data, Data) in
                var v = ByteWriter()
                v.u16le(value)
                return (Data(name.utf8), v.data)
            }.sorted { Data.bomLess($0.0, $1.0) }
            bom.addTree("LOCALIZATIONKEYS", entries: entries.map { (key: $0.0, value: $0.1) })
        }

        var kf = ByteWriter()
        kf.tag("tmfk")
        kf.u32le(0)
        kf.u32le(UInt32(format.count))
        for a in format { kf.u32le(UInt32(a.rawValue)) }
        bom.addVariable("KEYFORMAT", block: bom.addBlock(kf.data))

        var meta = ByteWriter()
        meta.tag("META")
        meta.fixedString("", length: 256)  // thinning arguments
        meta.fixedString(deploymentTarget, length: 256)
        meta.fixedString(platform, length: 256)
        meta.fixedString(authoringTool, length: 256)
        bom.addVariable("EXTENDED_METADATA", block: bom.addBlock(meta.data))

        // BITMAPKEYS: per name, a bitmask of the values each key attribute takes. CoreUI needs it to find vector glyphs.
        var masks: [UInt16: [UInt32]] = [:]
        for r in renditions {
            guard let id = r.key[.identifier] else { continue }
            var m = masks[id] ?? [UInt32](repeating: 0, count: format.count)
            for (i, a) in format.enumerated() {
                let v = r.key[a] ?? 0
                switch a {
                case .appearance, .identifier, .element, .part:
                    m[i] = 0xFFFF_FFFF
                case .localization, .subtype:
                    m[i] |= v == 0 ? 1 : 0xFFFF_FFFF
                default:
                    m[i] |= v < 32 ? (1 << UInt32(v)) : 0xFFFF_FFFF
                }
            }
            masks[id] = m
        }
        let bitmapEntries: [(key: Data, value: Data)] = facets.compactMap { f -> (UInt16, Data)? in
            guard let id = f.attributes[.identifier] else { return nil }
            var v = ByteWriter()
            v.u32le(1)
            v.u32le(0)
            v.u32le(UInt32(4 * (format.count + 1)))
            v.u32le(UInt32(format.count))
            let m = masks[id] ?? format.map { [.appearance, .identifier, .element, .part].contains($0) ? 0xFFFF_FFFF : 1 }
            for x in m { v.u32le(x) }
            return (id, v.data)
        }.sorted { $0.0 < $1.0 }.map { id, value in
            var k = ByteWriter()
            k.u32le(UInt32(id))
            return (key: k.data, value: value)
        }
        bom.addTree("BITMAPKEYS", entries: bitmapEntries, blockSize: 1024, inlineKeys: true)

        return bom.serialize()
    }
}
