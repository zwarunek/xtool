import CXTVendor
import Foundation

/// Premultiplied 8-bit pixels in B, G, R, A byte order (CoreUI's 'ARGB' little-endian layout).
public struct Bitmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case decode(String)
        case svg(String)
        case resize
        case encode

        var description: String {
            switch self {
            case .decode(let s): return "could not decode image \(s)"
            case .svg(let s): return "could not render SVG \(s)"
            case .resize: return "could not resize image"
            case .encode: return "could not encode PNG"
            }
        }
    }

    private static func take(_ b: inout xt_bitmap) -> Bitmap {
        let count = Int(b.width) * Int(b.height) * 4
        let pixels = [UInt8](UnsafeBufferPointer(start: b.pixels, count: count))
        xt_bitmap_free(&b)
        return Bitmap(width: Int(b.width), height: Int(b.height), pixels: pixels)
    }

    public static func decode(_ data: Data, name: String = "") throws -> Bitmap {
        var out = xt_bitmap()
        let rc = data.withUnsafeBytes { xt_image_decode($0.baseAddress, data.count, &out) }
        guard rc == 0 else { throw Error.decode(name) }
        return take(&out)
    }

    public static func svgSize(_ data: Data) -> (width: Double, height: Double)? {
        var w: Float = 0, h: Float = 0
        let rc = data.withUnsafeBytes { buf in
            xt_svg_size(buf.bindMemory(to: CChar.self).baseAddress, data.count, &w, &h)
        }
        guard rc == 0, w > 0, h > 0 else { return nil }
        return (Double(w), Double(h))
    }

    /// Renders at `scale` times the document's size into a width x height bitmap (stretches to fit when scale is nil).
    public static func renderSVG(_ data: Data, width: Int, height: Int, scale: Double? = nil, name: String = "") throws -> Bitmap {
        var out = xt_bitmap()
        let rc = data.withUnsafeBytes { buf in
            xt_svg_render(buf.bindMemory(to: CChar.self).baseAddress, data.count, Int32(width), Int32(height), Float(scale ?? 0), &out)
        }
        guard rc == 0 else { throw Error.svg(name) }
        return take(&out)
    }

    public func resized(width: Int, height: Int) throws -> Bitmap {
        if width == self.width && height == self.height { return self }
        var out = xt_bitmap()
        var input = pixels
        let rc = input.withUnsafeMutableBufferPointer { buf -> Int32 in
            var src = xt_bitmap(width: Int32(self.width), height: Int32(self.height), pixels: buf.baseAddress)
            return xt_resize(&src, Int32(width), Int32(height), &out)
        }
        guard rc == 0 else { throw Error.resize }
        return Bitmap.take(&out)
    }

    public func pngData() throws -> Data {
        var input = pixels
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let rc = input.withUnsafeMutableBufferPointer { buf -> Int32 in
            var src = xt_bitmap(width: Int32(width), height: Int32(height), pixels: buf.baseAddress)
            return xt_png_encode(&src, &out, &length)
        }
        guard rc == 0, let out else { throw Error.encode }
        defer { xt_free(out) }
        return Data(bytes: out, count: length)
    }

    /// Multiplies color by alpha a second time. actool does this to palette PNGs of 1, 2 or 4 bits per pixel
    /// that carry a tRNS chunk, so their translucent pixels come out darker; matching it keeps the look of Xcode builds.
    public mutating func premultiplyAgain() {
        var i = 0
        while i < pixels.count {
            let a = UInt32(pixels[i + 3])
            if a != 255 {
                pixels[i] = UInt8((UInt32(pixels[i]) * a + 127) / 255)
                pixels[i + 1] = UInt8((UInt32(pixels[i + 1]) * a + 127) / 255)
                pixels[i + 2] = UInt8((UInt32(pixels[i + 2]) * a + 127) / 255)
            }
            i += 4
        }
    }

    /// True when every pixel is fully opaque.
    public var isOpaque: Bool {
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return false }
            i += 4
        }
        return true
    }

    /// True when every pixel has equal red, green and blue (CoreUI stores those as gray + alpha).
    public var isGrayscale: Bool {
        var i = 0
        while i < pixels.count {
            if pixels[i] != pixels[i + 1] || pixels[i] != pixels[i + 2] { return false }
            i += 4
        }
        return true
    }

    /// Gray + alpha bytes (premultiplied), CoreUI's 'GA8 ' format.
    public var grayAlphaPixels: [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 2)
        var j = 0
        var i = 0
        while i < pixels.count {
            out[j] = pixels[i]
            out[j + 1] = pixels[i + 3]
            i += 4
            j += 2
        }
        return out
    }
}

enum PNGInfo {
    /// True for palette PNGs (color type 3) with fewer than 8 bits per pixel that carry a tRNS chunk.
    static func isIndexedWithTransparency(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(1 << 20))
        guard bytes.count > 33, bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), bytes[25] == 3, bytes[24] < 8 else { return false }
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if type == "tRNS" { return true }
            if type == "IDAT" || type == "IEND" { return false }
            offset += 12 + length
        }
        return false
    }
}
