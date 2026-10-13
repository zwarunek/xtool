import CXTVendor
import Foundation

enum LZFSE {
    static func encode(_ data: Data) -> Data? {
        if data.isEmpty { return nil }
        let capacity = data.count + 4096
        var out = Data(count: capacity)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(lzfse_encode_scratch_size(), 1), alignment: 16)
        defer { scratch.deallocate() }
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                lzfse_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, scratch)
            }
        }
        if written == 0 { return nil }
        out.count = written
        return out
    }

    static func decode(_ data: Data, expectedSize: Int? = nil) -> Data? {
        if data.isEmpty { return Data() }
        var capacity = max(expectedSize ?? data.count * 8, 4096)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(lzfse_decode_scratch_size(), 1), alignment: 16)
        defer { scratch.deallocate() }
        while capacity < 1 << 30 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    lzfse_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, data.count, scratch)
                }
            }
            if written == 0 { return nil }
            if written < capacity {
                out.count = written
                return out
            }
            capacity *= 4
        }
        return nil
    }
}

enum Zlib {
    static func compress(_ data: Data) -> Data? {
        var length: Int32 = 0
        let result = data.withUnsafeBytes { src -> UnsafeMutablePointer<UInt8>? in
            xt_zlib_compress(src.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &length)
        }
        guard let result else { return nil }
        defer { xt_free(result) }
        return Data(bytes: result, count: Int(length))
    }

    static func decompress(_ data: Data) -> Data? {
        var length: Int32 = 0
        let result = data.withUnsafeBytes { src -> UnsafeMutablePointer<UInt8>? in
            xt_zlib_decompress(src.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &length)
        }
        guard let result else { return nil }
        defer { xt_free(result) }
        return Data(bytes: result, count: Int(length))
    }
}

/// gzip (RFC 1952) framing around zlib's deflate stream, the form CoreUI's "zip" compression reads.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let z = Zlib.compress(data), z.count >= 6 else { return nil }
        let deflate = z.subdata(in: (z.startIndex + 2)..<(z.endIndex - 4))
        var w = ByteWriter(capacity: deflate.count + 18)
        w.bytes([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0])
        w.bytes(deflate)
        w.u32le(CRC32.checksum(data))
        w.u32le(UInt32(truncatingIfNeeded: data.count))
        return w.data
    }

    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        let flags = data[data.startIndex + 3]
        var offset = 10
        if flags & 4 != 0 {
            var r = ByteReader(data, offset: offset)
            let xlen = Int((try? r.u16le()) ?? 0)
            offset += 2 + xlen
        }
        if flags & 8 != 0 { while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 16 != 0 { while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 2 != 0 { offset += 2 }
        let body = data.subdata(in: (data.startIndex + offset)..<(data.endIndex - 8))
        // Wrap the raw deflate stream as zlib (header 78 9c, no checksum check by stb).
        var z = Data([0x78, 0x9c])
        z.append(body)
        z.append(contentsOf: [0, 0, 0, 0])
        return Zlib.decompress(z)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
