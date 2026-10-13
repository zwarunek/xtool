import Foundation

/// The kinds of folders an asset catalog can contain.
public enum AssetKind: String, Sendable {
    case imageSet = "imageset"
    case colorSet = "colorset"
    case appIconSet = "appiconset"
    case symbolSet = "symbolset"
    case dataSet = "dataset"
    case launchImage = "launchimage"
    case brandAssets = "brandassets"
    case imageStack = "imagestack"
    case imageStackLayer = "imagestacklayer"
    case iconSet = "iconset"
    case stickerPack = "stickerpack"
    case sticker = "sticker"
    case stickerSequence = "stickersequence"
    case textureSet = "textureset"
    case cubeTextureSet = "cubetextureset"
    case mipmapSet = "mipmapset"
    case spriteAtlas = "spriteatlas"
    case arResourceGroup = "arresourcegroup"
    case complicationSet = "complicationset"
    case solidImageStack = "solidimagestack"
    case gcDashboardImage = "gcdashboardimage"
    case gcLeaderboard = "gcleaderboard"
    case gcLeaderboardSet = "gcleaderboardset"
}

/// One asset (an `.imageset`, `.colorset`, ...) with its fully qualified name.
public struct Asset: Sendable {
    public var name: String
    public var kind: AssetKind
    public var directory: URL
    public var contents: [String: JSONValue]
    /// Namespace folder names leading to this asset (only folders with `provides-namespace`).
    public var namespace: [String]
}

/// A parsed `.xcassets` directory.
public struct AssetCatalog: Sendable {
    public var url: URL
    public var assets: [Asset]
    /// Every file and folder read, for the dependency info file.
    public var inputPaths: [String]

    public enum Error: Swift.Error, CustomStringConvertible {
        case notADirectory(String)
        case badContents(String, String)

        public var description: String {
            switch self {
            case .notADirectory(let p): return "\(p) is not an asset catalog directory"
            case .badContents(let p, let m): return "\(p): \(m)"
            }
        }
    }

    public init(url: URL) throws {
        self.url = url
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw Error.notADirectory(url.path)
        }
        var assets: [Asset] = []
        var inputs: [String] = [url.path]
        try AssetCatalog.walk(url, namespace: [], into: &assets, inputs: &inputs)
        self.assets = assets
        self.inputPaths = inputs
    }

    static func readContents(_ dir: URL) throws -> [String: JSONValue] {
        let file = dir.appendingPathComponent("Contents.json")
        guard let data = FileManager.default.contents(atPath: file.path) else { return [:] }
        do {
            let value = try JSONValue.parse(data)
            return value.object ?? [:]
        } catch {
            throw Error.badContents(file.path, "\(error)")
        }
    }

    private static func walk(_ dir: URL, namespace: [String], into assets: inout [Asset], inputs: inout [String]) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        for child in children where !child.hasPrefix(".") {
            let url = dir.appendingPathComponent(child)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            inputs.append(url.path)
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            if let kind = AssetKind(rawValue: ext) {
                let contents = try readContents(url)
                let name = (namespace + [base]).joined(separator: "/")
                assets.append(Asset(name: name, kind: kind, directory: url, contents: contents, namespace: namespace))
                if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                    for f in files.sorted() where !f.hasPrefix(".") { inputs.append(url.appendingPathComponent(f).path) }
                }
            } else {
                let contents = try readContents(url)
                let props = contents["properties"]?.object ?? [:]
                let providesNamespace = props["provides-namespace"]?.bool ?? false
                try walk(url, namespace: providesNamespace ? namespace + [child] : namespace, into: &assets, inputs: &inputs)
            }
        }
    }
}

/// A small JSON value type (Foundation's JSONSerialization differs between platforms in how it boxes numbers).
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double, String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(_, let raw): return raw
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased())
        case .number(let d, _): return d != 0
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let d, _): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    struct ParseError: Swift.Error, CustomStringConvertible {
        var offset: Int
        var message: String
        var description: String { "JSON error at byte \(offset): \(message)" }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        let v = try p.value()
        p.skipWhitespace()
        if p.i != p.bytes.count { throw ParseError(offset: p.i, message: "trailing characters") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            // Skip a UTF-8 byte order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { self.bytes = Array(bytes.dropFirst(3)) } else { self.bytes = bytes }
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw ParseError(offset: i, message: "unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var obj: [String: JSONValue] = [:]
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                while true {
                    skipWhitespace()
                    guard case .string(let key) = try value() else { throw ParseError(offset: i, message: "expected key") }
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError(offset: i, message: "expected :") }
                    i += 1
                    skipWhitespace()
                    obj[key] = try value()
                    skipWhitespace()
                    guard i < bytes.count else { throw ParseError(offset: i, message: "unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                    throw ParseError(offset: i, message: "expected , or }")
                }
            case UInt8(ascii: "["):
                i += 1
                var arr: [JSONValue] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                while true {
                    skipWhitespace()
                    arr.append(try value())
                    skipWhitespace()
                    guard i < bytes.count else { throw ParseError(offset: i, message: "unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                    throw ParseError(offset: i, message: "expected , or ]")
                }
            case UInt8(ascii: "\""):
                i += 1
                var out = [UInt8]()
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                    if bytes[i] == UInt8(ascii: "\\") {
                        i += 1
                        guard i < bytes.count else { break }
                        let c = bytes[i]
                        switch c {
                        case UInt8(ascii: "n"): out.append(0x0A)
                        case UInt8(ascii: "t"): out.append(0x09)
                        case UInt8(ascii: "r"): out.append(0x0D)
                        case UInt8(ascii: "b"): out.append(0x08)
                        case UInt8(ascii: "f"): out.append(0x0C)
                        case UInt8(ascii: "u"):
                            let hex = String(decoding: bytes[(i + 1)..<min(i + 5, bytes.count)], as: UTF8.self)
                            i += 4
                            var scalar = UInt32(hex, radix: 16) ?? 0xFFFD
                            if (0xD800..<0xDC00).contains(scalar), i + 6 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") {
                                let low = UInt32(String(decoding: bytes[(i + 3)..<(i + 7)], as: UTF8.self), radix: 16) ?? 0
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                                i += 6
                            }
                            out.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
                        default: out.append(c)
                        }
                        i += 1
                    } else {
                        out.append(bytes[i])
                        i += 1
                    }
                }
                i += 1
                return .string(String(decoding: out, as: UTF8.self))
            case UInt8(ascii: "t"):
                i += 4
                return .bool(true)
            case UInt8(ascii: "f"):
                i += 5
                return .bool(false)
            case UInt8(ascii: "n"):
                i += 4
                return .null
            default:
                let start = i
                while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
                let raw = String(decoding: bytes[start..<i], as: UTF8.self)
                guard let d = Double(raw) else { throw ParseError(offset: start, message: "bad number") }
                return .number(d, raw)
            }
        }
    }
}
