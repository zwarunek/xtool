import Foundation

/// One object in a NIBArchive: a class name and an ordered list of keyed values.
/// Keys may repeat (array and dictionary elements all use `UINibEncoderEmptyKey`).
public final class NibObject {
    public var className: String
    public var values: [(key: String, value: NibValue)] = []
    /// Fallback class names written after the class name (UIKit uses this for UIColor -> NSColor and similar).
    public var classFallbacks: [String] = []

    public init(_ className: String, fallbacks: [String] = []) {
        self.className = className
        self.classFallbacks = fallbacks
    }

    public func add(_ key: String, _ value: NibValue) {
        values.append((key, value))
    }

    public subscript(key: String) -> NibValue? {
        values.first { $0.key == key }?.value
    }
}

public enum NibValue {
    case int(Int64)
    case bool(Bool)
    case float(Float)
    case double(Double)
    case data([UInt8])
    case null
    case object(NibObject)

    public static func ints(_ value: Int) -> NibValue { .int(Int64(value)) }
}

public enum NibArchiveError: Error, CustomStringConvertible {
    case notANib
    case truncated(String)

    public var description: String {
        switch self {
        case .notANib: return "missing NIBArchive magic"
        case .truncated(let what): return "truncated archive while reading \(what)"
        }
    }
}

/// Reads and writes the binary NIBArchive format that UINib loads (header "NIBArchive", format 1, coder 10).
public enum NibArchive {
    static let magic = Array("NIBArchive".utf8)
    static let formatVersion: Int32 = 1
    static let coderVersion: Int32 = 10

    // MARK: Writing

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func encode(root: NibObject) -> [UInt8] {
        var objects: [NibObject] = []
        var objectIndex: [ObjectIdentifier: Int] = [:]
        // Pre-order depth-first numbering, the same order UINibEncoder visits objects.
        func visit(_ object: NibObject) {
            let id = ObjectIdentifier(object)
            if objectIndex[id] != nil { return }
            objectIndex[id] = objects.count
            objects.append(object)
            for (_, value) in object.values {
                if case .object(let child) = value { visit(child) }
            }
        }
        visit(root)

        var keys: [String] = []
        var keyIndex: [String: Int] = [:]
        var classes: [String] = []
        var classIndex: [String: Int] = [:]
        func internKey(_ key: String) -> Int {
            if let i = keyIndex[key] { return i }
            keyIndex[key] = keys.count
            keys.append(key)
            return keys.count - 1
        }
        func internClass(_ name: String) -> Int {
            if let i = classIndex[name] { return i }
            classIndex[name] = classes.count
            classes.append(name)
            return classes.count - 1
        }
        var classFallbacks: [String: [String]] = [:]
        for object in objects {
            _ = internClass(object.className)
            if !object.classFallbacks.isEmpty { classFallbacks[object.className] = object.classFallbacks }
        }
        for fallbacks in classFallbacks.values {
            for name in fallbacks { _ = internClass(name) }
        }

        var objectTable: [UInt8] = []
        var valueTable: [UInt8] = []
        var valueCount = 0
        for object in objects {
            writeVarint(classIndex[object.className]!, to: &objectTable)
            writeVarint(valueCount, to: &objectTable)
            writeVarint(object.values.count, to: &objectTable)
            for (key, value) in object.values {
                writeVarint(internKey(key), to: &valueTable)
                switch value {
                case .int(let v):
                    if v >= 0 && v <= Int64(Int8.max) {
                        valueTable.append(0)
                        valueTable.append(UInt8(v))
                    } else if v >= 0 && v <= Int64(Int16.max) {
                        valueTable.append(1)
                        appendLE(UInt16(v), to: &valueTable)
                    } else if v >= 0 && v <= Int64(Int32.max) {
                        valueTable.append(2)
                        appendLE(UInt32(v), to: &valueTable)
                    } else {
                        valueTable.append(3)
                        appendLE(UInt64(bitPattern: v), to: &valueTable)
                    }
                case .bool(let b):
                    valueTable.append(b ? 5 : 4)
                case .float(let f):
                    valueTable.append(6)
                    appendLE(f.bitPattern, to: &valueTable)
                case .double(let d):
                    valueTable.append(7)
                    appendLE(d.bitPattern, to: &valueTable)
                case .data(let bytes):
                    valueTable.append(8)
                    writeVarint(bytes.count, to: &valueTable)
                    valueTable.append(contentsOf: bytes)
                case .null:
                    valueTable.append(9)
                case .object(let child):
                    valueTable.append(10)
                    appendLE(UInt32(objectIndex[ObjectIdentifier(child)]!), to: &valueTable)
                }
                valueCount += 1
            }
        }

        var keyTable: [UInt8] = []
        for key in keys {
            let bytes = Array(key.utf8)
            writeVarint(bytes.count, to: &keyTable)
            keyTable.append(contentsOf: bytes)
        }

        var classTable: [UInt8] = []
        for name in classes {
            let bytes = Array(name.utf8) + [0]
            let fallbacks = classFallbacks[name] ?? []
            writeVarint(bytes.count, to: &classTable)
            writeVarint(fallbacks.count, to: &classTable)
            for fallback in fallbacks {
                appendLE(UInt32(classIndex[fallback]!), to: &classTable)
            }
            classTable.append(contentsOf: bytes)
        }

        let headerSize = magic.count + 40
        let objectsOffset = headerSize
        let keysOffset = objectsOffset + objectTable.count
        let valuesOffset = keysOffset + keyTable.count
        let classesOffset = valuesOffset + valueTable.count

        var out = magic
        for field in [formatVersion, coderVersion,
                      Int32(objects.count), Int32(objectsOffset),
                      Int32(keys.count), Int32(keysOffset),
                      Int32(valueCount), Int32(valuesOffset),
                      Int32(classes.count), Int32(classesOffset)] {
            appendLE(UInt32(bitPattern: field), to: &out)
        }
        out += objectTable
        out += keyTable
        out += valueTable
        out += classTable
        return out
    }

    static func writeVarint(_ value: Int, to out: inout [UInt8]) {
        // 7 bits per byte, least significant group first; the high bit marks the last byte.
        var v = value
        while true {
            let byte = UInt8(v & 0x7f)
            v >>= 7
            if v == 0 {
                out.append(byte | 0x80)
                return
            }
            out.append(byte)
        }
    }

    static func appendLE<T: FixedWidthInteger>(_ value: T, to out: inout [UInt8]) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    // MARK: Reading

    /// Decodes a NIBArchive into its object graph; returns the root (object 0).
    public static func decode(_ bytes: [UInt8]) throws -> NibObject { // swiftlint:disable:this cyclomatic_complexity
        guard bytes.count >= 50, Array(bytes[0..<10]) == magic else { throw NibArchiveError.notANib }
        func u32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        let objectCount = u32(18), objectsOffset = u32(22)
        let keyCount = u32(26), keysOffset = u32(30)
        let valueCount = u32(34), valuesOffset = u32(38)
        let classCount = u32(42), classesOffset = u32(46)

        var cursor = 0
        func byte() throws -> UInt8 {
            guard cursor < bytes.count else { throw NibArchiveError.truncated("byte") }
            defer { cursor += 1 }
            return bytes[cursor]
        }
        func varint() throws -> Int {
            var result = 0, shift = 0
            while true {
                let b = try byte()
                result |= Int(b & 0x7f) << shift
                if b & 0x80 != 0 { return result }
                shift += 7
            }
        }
        func take(_ n: Int) throws -> [UInt8] {
            guard cursor + n <= bytes.count else { throw NibArchiveError.truncated("data") }
            defer { cursor += n }
            return Array(bytes[cursor..<cursor + n])
        }
        func le(_ n: Int) throws -> UInt64 {
            let b = try take(n)
            return b.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }

        cursor = classesOffset
        var classes: [(String, [Int])] = []
        for _ in 0..<classCount {
            let length = try varint()
            let extras = try varint()
            var fallback: [Int] = []
            for _ in 0..<extras { fallback.append(Int(try le(4))) }
            let name = try take(length)
            classes.append((String(decoding: name.prefix { $0 != 0 }, as: UTF8.self), fallback))
        }

        cursor = keysOffset
        var keys: [String] = []
        for _ in 0..<keyCount {
            let length = try varint()
            keys.append(String(decoding: try take(length), as: UTF8.self))
        }

        enum Raw { case value(NibValue), ref(Int) }
        cursor = valuesOffset
        var rawValues: [(String, Raw)] = []
        for _ in 0..<valueCount {
            let key = keys[try varint()]
            let type = try byte()
            let raw: Raw
            switch type {
            case 0: raw = .value(.int(Int64(Int8(bitPattern: try byte()))))
            case 1: raw = .value(.int(Int64(Int16(bitPattern: UInt16(try le(2))))))
            case 2: raw = .value(.int(Int64(Int32(bitPattern: UInt32(try le(4))))))
            case 3: raw = .value(.int(Int64(bitPattern: try le(8))))
            case 4: raw = .value(.bool(false))
            case 5: raw = .value(.bool(true))
            case 6: raw = .value(.float(Float(bitPattern: UInt32(try le(4)))))
            case 7: raw = .value(.double(Double(bitPattern: try le(8))))
            case 8: raw = .value(.data(try take(try varint())))
            case 9: raw = .value(.null)
            case 10: raw = .ref(Int(try le(4)))
            default: throw NibArchiveError.truncated("value of unknown type \(type)")
            }
            rawValues.append((key, raw))
        }

        cursor = objectsOffset
        var spans: [(Int, Int, Int)] = []
        for _ in 0..<objectCount {
            spans.append((try varint(), try varint(), try varint()))
        }
        let objects = spans.map { span -> NibObject in
            let (name, fallback) = classes[span.0]
            return NibObject(name, fallbacks: fallback.map { classes[$0].0 })
        }
        for (object, span) in zip(objects, spans) {
            for (key, raw) in rawValues[span.1..<span.1 + span.2] {
                switch raw {
                case .value(let v): object.add(key, v)
                case .ref(let i): object.add(key, .object(objects[i]))
                }
            }
        }
        guard let root = objects.first else { throw NibArchiveError.truncated("objects") }
        return root
    }

    // MARK: Dumping

    /// A text rendering of the object graph, numbering objects in first-visit order.
    public static func dump(_ root: NibObject) -> String {
        var seen: [ObjectIdentifier: Int] = [:]
        var lines: [String] = []
        func visit(_ object: NibObject, depth: Int, label: String) {
            let pad = String(repeating: "  ", count: depth)
            if let n = seen[ObjectIdentifier(object)] {
                lines.append("\(pad)\(label) &\(n)")
                return
            }
            let n = seen.count
            seen[ObjectIdentifier(object)] = n
            lines.append("\(pad)\(label) #\(n) \(object.className)")
            for (key, value) in object.values {
                switch value {
                case .object(let child): visit(child, depth: depth + 1, label: key + ":")
                default: lines.append("\(pad)  \(key): \(describe(value))")
                }
            }
        }
        visit(root, depth: 0, label: "root")
        return lines.joined(separator: "\n") + "\n"
    }

    static func describe(_ value: NibValue) -> String {
        switch value {
        case .int(let v): return "int \(v)"
        case .bool(let b): return b ? "true" : "false"
        case .float(let f): return "f \(f)"
        case .double(let d): return "d \(d)"
        case .null: return "nil"
        case .object: return "object"
        case .data(let bytes):
            if bytes.first == 0x07, (bytes.count - 1) % 8 == 0, bytes.count > 1 {
                let doubles = stride(from: 1, to: bytes.count, by: 8).map { i -> Double in
                    let bits = bytes[i..<i + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
                    return Double(bitPattern: bits)
                }
                return "doubles \(doubles)"
            }
            if let s = String(bytes: bytes, encoding: .utf8), !s.contains("\0") {
                return "data '\(s)'"
            }
            return "data 0x" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}
