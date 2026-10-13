import Foundation

public enum ActoolVersion {
    public static let bundleVersion = "24765"
    public static let shortVersion = "26.5"
}

/// Reads CAR files: facets, rendition keys, CSI headers and (for formats this tool writes) payloads.
public struct CARReader {
    public struct Rendition {
        public var key: [CARAttribute: UInt16]
        public var flags: UInt32
        public var width: UInt32
        public var height: UInt32
        public var scaleFactor: UInt32
        public var pixelFormat: String
        public var colorSpaceID: UInt32
        public var layout: UInt16
        public var name: String
        public var info: [(type: UInt32, payload: Data)]
        public var payload: Data

        public var payloadTag: String { payload.count >= 4 ? String(decoding: payload.prefix(4), as: UTF8.self) : "" }

        /// Decodes pixel payloads written with no, zip or LZFSE compression (not Apple's deepmap formats).
        public func decodedPixels() -> Data? {
            guard payloadTag == "MLEC" else { return nil }
            var r = ByteReader(payload, offset: 4)
            guard let _ = try? r.u32le(), let compression = try? r.u32le(), let length = try? r.u32le(),
                  let body = try? r.bytes(Int(length)) else { return nil }
            switch compression {
            case 0: return body
            case 2: return Gzip.decompress(body) ?? Zlib.decompress(body)
            case 4: return LZFSE.decode(body, expectedSize: Int(width * height * 4) + 64)
            default: return nil
            }
        }

        /// Returns the bitmap for ARGB and GA8 renditions this tool can decode.
        public func bitmap() -> Bitmap? {
            guard let raw = decodedPixels() else { return nil }
            let w = Int(width), h = Int(height)
            var rowBytes = 0
            for i in info where i.type == CSIInfo.bytesPerRow {
                var rr = ByteReader(i.payload)
                rowBytes = Int((try? rr.u32le()) ?? 0)
            }
            let bytes = [UInt8](raw)
            var out = Bitmap(width: w, height: h)
            if pixelFormat == "ARGB" {
                let stride = rowBytes > 0 ? rowBytes : w * 4
                guard bytes.count >= stride * (h - 1) + w * 4 else { return nil }
                for y in 0..<h { for x in 0..<(w * 4) { out.pixels[y * w * 4 + x] = bytes[y * stride + x] } }
            } else if pixelFormat == "GA8 " {
                let stride = rowBytes > 0 ? rowBytes : w * 2
                guard bytes.count >= stride * (h - 1) + w * 2 else { return nil }
                for y in 0..<h {
                    for x in 0..<w {
                        let g = bytes[y * stride + x * 2], a = bytes[y * stride + x * 2 + 1]
                        let o = (y * w + x) * 4
                        out.pixels[o] = g; out.pixels[o + 1] = g; out.pixels[o + 2] = g; out.pixels[o + 3] = a
                    }
                }
            } else {
                return nil
            }
            return out
        }

        /// The bytes inside a raw-data ("DWAR") payload, decompressed.
        public func rawData() -> Data? {
            guard payloadTag == "DWAR" else { return nil }
            var r = ByteReader(payload, offset: 4)
            guard let flag = try? r.u32le(), let length = try? r.u32le(), let body = try? r.bytes(Int(length)) else { return nil }
            return flag == 1 ? LZFSE.decode(body) : body
        }

        /// Color space id and components of a color ("RLOC") payload.
        public func color() -> (space: UInt32, components: [Double])? {
            guard payloadTag == "RLOC" else { return nil }
            var r = ByteReader(payload, offset: 4)
            guard let _ = try? r.u32le(), let space = try? r.u32le(), let n = try? r.u32le() else { return nil }
            var comps: [Double] = []
            for _ in 0..<n { if let d = try? r.f64le() { comps.append(d) } }
            return (space, comps)
        }
    }

    public var keyFormat: [UInt32] = []
    public var facets: [String: [CARAttribute: UInt16]] = [:]
    public var renditions: [Rendition] = []
    public var appearances: [String: UInt16] = [:]
    public var localizations: [String: UInt16] = [:]
    public var variables: [String] = []
    public var headerVersion: (ui: UInt32, storage: UInt32) = (0, 0)
    public var deploymentTarget = ""
    public var platform = ""

    public init(_ data: Data) throws {
        let bom = try BOMReader(data)
        variables = bom.variables.map(\.name)
        var hr = ByteReader(try bom.variable("CARHEADER"))
        _ = try hr.tag()
        headerVersion = (try hr.u32le(), try hr.u32le())
        if bom.hasVariable("EXTENDED_METADATA") {
            var mr = ByteReader(try bom.variable("EXTENDED_METADATA"))
            _ = try mr.tag()
            _ = try mr.cString(length: 256)
            deploymentTarget = try mr.cString(length: 256)
            platform = try mr.cString(length: 256)
        }
        var kr = ByteReader(try bom.variable("KEYFORMAT"))
        _ = try kr.tag()
        _ = try kr.u32le()
        let n = try kr.u32le()
        for _ in 0..<n { keyFormat.append(try kr.u32le()) }

        for (k, v) in try bom.tree("FACETKEYS") {
            var r = ByteReader(v)
            _ = try r.u16le()
            _ = try r.u16le()
            let count = try r.u16le()
            var attrs: [CARAttribute: UInt16] = [:]
            for _ in 0..<count {
                let a = try r.u16le(), value = try r.u16le()
                if let attr = CARAttribute(rawValue: a) { attrs[attr] = value }
            }
            facets[String(decoding: k, as: UTF8.self)] = attrs
        }
        for name in ["APPEARANCEKEYS", "LOCALIZATIONKEYS"] where bom.hasVariable(name) {
            for (k, v) in try bom.tree(name) {
                var r = ByteReader(v)
                let value = (try? r.u16le()) ?? 0
                if name == "APPEARANCEKEYS" { appearances[String(decoding: k, as: UTF8.self)] = value } else { localizations[String(decoding: k, as: UTF8.self)] = value }
            }
        }
        for (k, v) in try bom.tree("RENDITIONS") {
            var key: [CARAttribute: UInt16] = [:]
            var kr = ByteReader(k)
            for id in keyFormat {
                guard let value = try? kr.u16le() else { break }
                if let attr = CARAttribute(rawValue: UInt16(id)) { key[attr] = value }
            }
            renditions.append(try Self.parseCSI(v, key: key))
        }
    }

    static func parseCSI(_ v: Data, key: [CARAttribute: UInt16]) throws -> Rendition {
        var r = ByteReader(v)
        _ = try r.tag()
        _ = try r.u32le()
        let flags = try r.u32le()
        let width = try r.u32le()
        let height = try r.u32le()
        let scale = try r.u32le()
        let pf = try r.u32le()
        let cs = try r.u32le()
        _ = try r.u32le()
        let layout = try r.u16le()
        _ = try r.u16le()
        let name = try r.cString(length: 128)
        let infoLength = Int(try r.u32le())
        _ = try r.u32le()
        _ = try r.u32le()
        let payloadSize = Int(try r.u32le())
        var info: [(UInt32, Data)] = []
        let infoEnd = r.offset + infoLength
        while r.offset + 8 <= infoEnd {
            let t = try r.u32le()
            let l = Int(try r.u32le())
            info.append((t, try r.bytes(l)))
        }
        r.offset = infoEnd
        let payload = try r.bytes(min(payloadSize, v.count - r.offset))
        return Rendition(key: key, flags: flags, width: width, height: height, scaleFactor: scale, pixelFormat: fourCCString(pf),
                         colorSpaceID: cs & 0xf, layout: layout, name: name, info: info, payload: payload)
    }

    /// Renditions grouped by the facet name they belong to.
    public func renditions(named name: String) -> [Rendition] {
        guard let id = facets[name]?[.identifier] else { return [] }
        return renditions.filter { $0.key[.identifier] == id }
    }
}

public enum CARDump {
    public static func describe(_ data: Data) throws -> String {
        let car = try CARReader(data)
        var lines: [String] = []
        lines.append("variables: \(car.variables.joined(separator: ", "))")
        lines.append("header: ui \(car.headerVersion.ui) storage \(car.headerVersion.storage) deployment \(car.deploymentTarget) platform \(car.platform)")
        lines.append("keyformat: \(car.keyFormat.map { CARAttribute(rawValue: UInt16($0))?.name ?? "\($0)" }.joined(separator: ", "))")
        lines.append("appearances: \(car.appearances.sorted { $0.value < $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        if !car.localizations.isEmpty { lines.append("localizations: \(car.localizations)") }
        for name in car.facets.keys.sorted() {
            let attrs = car.facets[name]!.sorted { $0.key < $1.key }.map { "\($0.key.name)=\($0.value)" }.joined(separator: " ")
            lines.append("facet \(name): \(attrs)")
            for r in car.renditions(named: name).sorted(by: { "\($0.key.sorted { $0.key < $1.key }.map(\.value))" < "\($1.key.sorted { $0.key < $1.key }.map(\.value))" }) {
                let key = r.key.filter { $0.value != 0 && ![.identifier, .element].contains($0.key) }.sorted { $0.key < $1.key }.map { "\($0.key.name)=\($0.value)" }.joined(separator: " ")
                var line = "  [\(key)] layout=\(r.layout) \(r.pixelFormat.isEmpty ? "-" : r.pixelFormat) \(r.width)x\(r.height)@\(r.scaleFactor) flags=0x\(String(r.flags, radix: 16)) cs=\(r.colorSpaceID) \(r.payloadTag) \"\(r.name)\""
                if let c = r.color() { line += " color(space \(c.space): \(c.components.map { String(format: "%.4f", $0) }.joined(separator: " ")))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
