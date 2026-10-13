import Foundation

/// Appends fixed-width integers and raw bytes to a growing buffer.
struct ByteWriter {
    var data = Data()

    init() {}

    init(capacity: Int) {
        data.reserveCapacity(capacity)
    }

    var count: Int { data.count }

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16le(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32le(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u16be(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32be(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32le(_ value: Float) { u32le(value.bitPattern) }
    mutating func f64le(_ value: Double) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }

    mutating func bytes(_ bytes: Data) { data.append(bytes) }
    mutating func bytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

    /// Writes a four-character code in the order it reads ("ISTC" is stored as the bytes I, S, T, C).
    mutating func tag(_ string: String) {
        let utf8 = Array(string.utf8)
        precondition(utf8.count == 4)
        data.append(contentsOf: utf8)
    }

    /// Writes `string` as UTF-8 into a zero-padded field of `length` bytes.
    mutating func fixedString(_ string: String, length: Int) {
        var utf8 = Array(string.utf8.prefix(length - 1))
        utf8.append(contentsOf: [UInt8](repeating: 0, count: length - utf8.count))
        data.append(contentsOf: utf8)
    }

    mutating func zeros(_ count: Int) {
        data.append(contentsOf: [UInt8](repeating: 0, count: count))
    }

    mutating func align(_ alignment: Int) {
        let remainder = data.count % alignment
        if remainder != 0 { zeros(alignment - remainder) }
    }
}

/// Reads fixed-width integers from a byte buffer.
struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    enum Error: Swift.Error { case outOfBounds(Int) }

    private func check(_ count: Int) throws {
        if offset < 0 || offset + count > data.count { throw Error.outOfBounds(offset) }
    }

    mutating func u8() throws -> UInt8 {
        try check(1)
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16le() throws -> UInt16 {
        try check(2)
        defer { offset += 2 }
        let b = data.startIndex + offset
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }

    mutating func u32le() throws -> UInt32 {
        try check(4)
        defer { offset += 4 }
        let b = data.startIndex + offset
        return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
    }

    mutating func u32be() throws -> UInt32 {
        try check(4)
        defer { offset += 4 }
        let b = data.startIndex + offset
        return UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
    }

    mutating func u16be() throws -> UInt16 {
        try check(2)
        defer { offset += 2 }
        let b = data.startIndex + offset
        return UInt16(data[b]) << 8 | UInt16(data[b + 1])
    }

    mutating func f32le() throws -> Float { Float(bitPattern: try u32le()) }

    mutating func f64le() throws -> Double {
        let lo = UInt64(try u32le())
        let hi = UInt64(try u32le())
        return Double(bitPattern: hi << 32 | lo)
    }

    mutating func bytes(_ count: Int) throws -> Data {
        try check(count)
        defer { offset += count }
        let b = data.startIndex + offset
        return data.subdata(in: b..<(b + count))
    }

    mutating func tag() throws -> String {
        String(decoding: try bytes(4), as: UTF8.self)
    }

    mutating func cString(length: Int) throws -> String {
        let raw = try bytes(length)
        let end = raw.firstIndex(of: 0) ?? raw.endIndex
        return String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
    }
}

extension Data {
    /// Lexicographic byte comparison, the order BOM trees keep their keys in.
    static func bomLess(_ a: Data, _ b: Data) -> Bool {
        a.lexicographicallyPrecedes(b)
    }
}
