import CXTVendor
import Foundation

/// A small PDF reader and renderer for vector icons: paths, solid colors, opacity, clipping,
/// form and image XObjects, axial and radial shadings and Type 3 fonts. Other text is skipped.
public final class PDFDocument {
    indirect enum Obj {
        case null
        case bool(Bool)
        case num(Double)
        case str([UInt8])
        case name(String)
        case array([Obj])
        case dict([String: Obj])
        case stream([String: Obj], Data)
        case ref(Int, Int)
        case op(String)

        var num: Double? { if case .num(let d) = self { return d } else { return nil } }
        var name: String? { if case .name(let n) = self { return n } else { return nil } }
        var array: [Obj]? { if case .array(let a) = self { return a } else { return nil } }
        var dict: [String: Obj]? {
            switch self {
            case .dict(let d): return d
            case .stream(let d, _): return d
            default: return nil
            }
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            switch self {
            case .malformed(let m): return "PDF: \(m)"
            }
        }
    }

    let bytes: [UInt8]
    var objects: [Int: Obj] = [:]
    var offsets: [Int: Int] = [:]
    var trailer: [String: Obj] = [:]

    public init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.starts(with: Array("%PDF".utf8)) else { throw Error.malformed("missing %PDF header") }
        scanObjects()
    }

    // MARK: Object lookup

    /// Finds "N G obj" headers by scanning, which tolerates broken or missing xref tables.
    private func scanObjects() {
        var i = 0
        let n = bytes.count
        while i < n - 4 {
            if bytes[i] == UInt8(ascii: "o"), bytes[i + 1] == UInt8(ascii: "b"), bytes[i + 2] == UInt8(ascii: "j"),
               i + 3 >= n || Lexer.isDelimiterOrSpace(bytes[i + 3]) {
                // Walk back over "N G ".
                var j = i - 1
                while j >= 0, Lexer.isSpace(bytes[j]) { j -= 1 }
                let genEnd = j + 1
                while j >= 0, Lexer.isDigit(bytes[j]) { j -= 1 }
                let genStart = j + 1
                while j >= 0, Lexer.isSpace(bytes[j]) { j -= 1 }
                let numEnd = j + 1
                while j >= 0, Lexer.isDigit(bytes[j]) { j -= 1 }
                let numStart = j + 1
                if genStart < genEnd, numStart < numEnd, j < 0 || Lexer.isSpace(bytes[j]) || Lexer.isDelimiterOrSpace(bytes[j]),
                   let num = Int(String(decoding: bytes[numStart..<numEnd], as: UTF8.self)) {
                    offsets[num] = i + 3
                }
                i += 3
                continue
            }
            if bytes[i] == UInt8(ascii: "t"), bytes[i...].starts(with: Array("trailer".utf8)) {
                var lexer = Lexer(bytes: bytes, pos: i + 7)
                if case .dict(let d)? = try? lexer.object(resolveStreams: nil) { trailer.merge(d) { a, _ in a } }
            }
            i += 1
        }
        // Objects inside object streams.
        for (num, _) in offsets {
            if case .stream(let d, _)? = object(num), d["Type"]?.name == "ObjStm" {
                loadObjectStream(num)
            }
        }
    }

    private func loadObjectStream(_ num: Int) {
        guard case .stream(let d, _)? = object(num), let data = streamData(object(num)!) else { return }
        let count = Int(resolve(d["N"])?.num ?? 0)
        let first = Int(resolve(d["First"])?.num ?? 0)
        let b = [UInt8](data)
        var lexer = Lexer(bytes: b, pos: 0)
        var pairs: [(Int, Int)] = []
        for _ in 0..<count {
            guard case .num(let on)? = try? lexer.object(resolveStreams: nil), case .num(let off)? = try? lexer.object(resolveStreams: nil) else { break }
            pairs.append((Int(on), Int(off)))
        }
        for (on, off) in pairs where objects[on] == nil && offsets[on] == nil {
            var l = Lexer(bytes: b, pos: first + off)
            if let o = try? l.object(resolveStreams: nil) { objects[on] = o }
        }
    }

    func object(_ num: Int) -> Obj? {
        if let o = objects[num] { return o }
        guard let off = offsets[num] else { return nil }
        var lexer = Lexer(bytes: bytes, pos: off)
        let o = try? lexer.object(resolveStreams: { [weak self] in self?.resolve($0)?.num })
        objects[num] = o ?? .null
        return o
    }

    func resolve(_ o: Obj?) -> Obj? {
        var cur = o
        var depth = 0
        while case .ref(let n, _)? = cur, depth < 32 {
            cur = object(n)
            depth += 1
        }
        return cur
    }

    func dict(_ o: Obj?) -> [String: Obj]? { resolve(o)?.dict }

    func streamData(_ o: Obj) -> Data? {
        guard case .stream(let d, let raw) = o else { return nil }
        var data = raw
        var filters: [String] = []
        var parms: [[String: Obj]?] = []
        switch resolve(d["Filter"]) {
        case .name(let n)?: filters = [n]
        case .array(let a)?: filters = a.compactMap { resolve($0)?.name }
        default: break
        }
        switch resolve(d["DecodeParms"]) {
        case .dict(let p)?: parms = [p]
        case .array(let a)?: parms = a.map { dict($0) }
        default: break
        }
        for (i, f) in filters.enumerated() {
            switch f {
            case "FlateDecode", "Fl":
                guard let out = Zlib.decompress(data) else { return nil }
                data = out
                if let p = i < parms.count ? parms[i] : nil, let predictor = resolve(p["Predictor"])?.num, predictor >= 10 {
                    let colors = Int(resolve(p["Colors"])?.num ?? 1)
                    let bpc = Int(resolve(p["BitsPerComponent"])?.num ?? 8)
                    let columns = Int(resolve(p["Columns"])?.num ?? 1)
                    data = Self.unpredictPNG(data, bytesPerPixel: max(1, colors * bpc / 8), rowBytes: (columns * colors * bpc + 7) / 8)
                }
            case "DCTDecode", "DCT":
                return data  // decoded by the image path
            default:
                return nil
            }
        }
        return data
    }

    static func unpredictPNG(_ data: Data, bytesPerPixel bpp: Int, rowBytes: Int) -> Data {
        let src = [UInt8](data)
        var out = [UInt8]()
        var prev = [UInt8](repeating: 0, count: rowBytes)
        var i = 0
        while i + rowBytes < src.count + 1, i < src.count {
            let type = src[i]
            i += 1
            var row = [UInt8](src[i..<min(i + rowBytes, src.count)])
            if row.count < rowBytes { row += [UInt8](repeating: 0, count: rowBytes - row.count) }
            for x in 0..<rowBytes {
                let a = x >= bpp ? Int(row[x - bpp]) : 0
                let b = Int(prev[x])
                let c = x >= bpp ? Int(prev[x - bpp]) : 0
                var v = Int(row[x])
                switch type {
                case 1: v += a
                case 2: v += b
                case 3: v += (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                default: break
                }
                row[x] = UInt8(truncatingIfNeeded: v)
            }
            out += row
            prev = row
            i += rowBytes
        }
        return Data(out)
    }

    // MARK: Pages

    func pages() -> [[String: Obj]] {
        var result: [[String: Obj]] = []
        guard let root = dict(trailer["Root"]) ?? findCatalog(), let tree = dict(root["Pages"]) else { return result }
        func walk(_ node: [String: Obj], inherited: [String: Obj], depth: Int) {
            guard depth < 64 else { return }
            var inh = inherited
            for k in ["Resources", "MediaBox", "CropBox"] where node[k] != nil { inh[k] = node[k] }
            if node["Type"]?.name == "Page" || node["Kids"] == nil {
                var page = node
                for (k, v) in inh where page[k] == nil { page[k] = v }
                result.append(page)
                return
            }
            for kid in resolve(node["Kids"])?.array ?? [] {
                if let d = dict(kid) { walk(d, inherited: inh, depth: depth + 1) }
            }
        }
        walk(tree, inherited: [:], depth: 0)
        return result
    }

    private func findCatalog() -> [String: Obj]? {
        for num in offsets.keys.sorted() {
            if let d = dict(object(num)), d["Type"]?.name == "Catalog" { return d }
        }
        return nil
    }

    func box(_ page: [String: Obj]) -> (x: Double, y: Double, w: Double, h: Double) {
        let arr = (resolve(page["CropBox"])?.array ?? resolve(page["MediaBox"])?.array ?? []).compactMap { resolve($0)?.num }
        guard arr.count == 4 else { return (0, 0, 612, 792) }
        let x0 = min(arr[0], arr[2]), x1 = max(arr[0], arr[2]), y0 = min(arr[1], arr[3]), y1 = max(arr[1], arr[3])
        return (x0, y0, x1 - x0, y1 - y0)
    }

    public func firstPageSize() throws -> (width: Double, height: Double) {
        guard let page = pages().first else { throw Error.malformed("no pages") }
        let b = box(page)
        let rotate = Int(resolve(page["Rotate"])?.num ?? 0)
        return rotate % 180 == 0 ? (b.w, b.h) : (b.h, b.w)
    }

    public func renderFirstPage(width: Int, height: Int) throws -> Bitmap {
        guard let page = pages().first else { throw Error.malformed("no pages") }
        guard let surface = plutovg_surface_create(Int32(width), Int32(height)) else { throw Error.malformed("surface") }
        defer { plutovg_surface_destroy(surface) }
        guard let canvas = plutovg_canvas_create(surface) else { throw Error.malformed("canvas") }
        defer { plutovg_canvas_destroy(canvas) }
        let b = box(page)
        let sx = Double(width) / b.w, sy = Double(height) / b.h
        let base = Matrix(a: sx, b: 0, c: 0, d: -sy, e: -b.x * sx, f: Double(height) + b.y * sy)
        let content: Data
        switch resolve(page["Contents"]) {
        case .array(let parts)?:
            var d = Data()
            for p in parts { if let s = resolve(p), let data = streamData(s) { d.append(data); d.append(0x0A) } }
            content = d
        case let s?:
            content = streamData(s) ?? Data()
        case nil:
            content = Data()
        }
        let renderer = Renderer(doc: self, canvas: canvas)
        renderer.state.ctm = base
        plutovg_canvas_save(canvas)
        renderer.applyClipRect(x: b.x, y: b.y, w: b.w, h: b.h)
        renderer.run(content, resources: dict(page["Resources"]) ?? [:], depth: 0)
        plutovg_canvas_restore(canvas)

        let stride = Int(plutovg_surface_get_stride(surface))
        guard let px = plutovg_surface_get_data(surface) else { throw Error.malformed("surface data") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width * 4) { pixels[y * width * 4 + x] = px[y * stride + x] }
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    // MARK: Lexer

    struct Lexer {
        let bytes: [UInt8]
        var pos: Int

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
        static func isDelimiter(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }
        static func isDelimiterOrSpace(_ c: UInt8) -> Bool { isSpace(c) || isDelimiter(c) }
        static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        var atEnd: Bool { pos >= bytes.count }

        mutating func skipSpace() {
            while pos < bytes.count {
                if Self.isSpace(bytes[pos]) {
                    pos += 1
                } else if bytes[pos] == UInt8(ascii: "%") {
                    while pos < bytes.count, bytes[pos] != 0x0A, bytes[pos] != 0x0D { pos += 1 }
                } else {
                    break
                }
            }
        }

        /// Reads one token: a value, or an operator keyword.
        mutating func token() throws -> Obj? {
            skipSpace()
            guard pos < bytes.count else { return nil }
            let c = bytes[pos]
            switch c {
            case UInt8(ascii: "/"):
                pos += 1
                var name = [UInt8]()
                while pos < bytes.count, !Self.isDelimiterOrSpace(bytes[pos]) {
                    if bytes[pos] == UInt8(ascii: "#"), pos + 2 < bytes.count, let v = UInt8(String(decoding: bytes[(pos + 1)...(pos + 2)], as: UTF8.self), radix: 16) {
                        name.append(v)
                        pos += 3
                    } else {
                        name.append(bytes[pos])
                        pos += 1
                    }
                }
                return .name(String(decoding: name, as: UTF8.self))
            case UInt8(ascii: "("):
                pos += 1
                var depth = 1
                var out = [UInt8]()
                while pos < bytes.count {
                    let ch = bytes[pos]
                    pos += 1
                    if ch == UInt8(ascii: "\\") {
                        guard pos < bytes.count else { break }
                        let e = bytes[pos]
                        pos += 1
                        switch e {
                        case UInt8(ascii: "n"): out.append(0x0A)
                        case UInt8(ascii: "r"): out.append(0x0D)
                        case UInt8(ascii: "t"): out.append(0x09)
                        case UInt8(ascii: "b"): out.append(0x08)
                        case UInt8(ascii: "f"): out.append(0x0C)
                        case 0x0D:
                            if pos < bytes.count, bytes[pos] == 0x0A { pos += 1 }
                        case 0x0A: break
                        case UInt8(ascii: "0")...UInt8(ascii: "7"):
                            var v = Int(e - 0x30)
                            for _ in 0..<2 where pos < bytes.count && bytes[pos] >= 0x30 && bytes[pos] <= 0x37 {
                                v = v * 8 + Int(bytes[pos] - 0x30)
                                pos += 1
                            }
                            out.append(UInt8(truncatingIfNeeded: v))
                        default: out.append(e)
                        }
                    } else if ch == UInt8(ascii: "(") {
                        depth += 1
                        out.append(ch)
                    } else if ch == UInt8(ascii: ")") {
                        depth -= 1
                        if depth == 0 { break }
                        out.append(ch)
                    } else {
                        out.append(ch)
                    }
                }
                return .str(out)
            case UInt8(ascii: "<"):
                if pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "<") {
                    pos += 2
                    return .op("<<")
                }
                pos += 1
                var hex = [UInt8]()
                while pos < bytes.count, bytes[pos] != UInt8(ascii: ">") {
                    if !Self.isSpace(bytes[pos]) { hex.append(bytes[pos]) }
                    pos += 1
                }
                pos += 1
                if hex.count % 2 == 1 { hex.append(UInt8(ascii: "0")) }
                var out = [UInt8]()
                var k = 0
                while k + 1 < hex.count {
                    out.append(UInt8(String(decoding: hex[k...(k + 1)], as: UTF8.self), radix: 16) ?? 0)
                    k += 2
                }
                return .str(out)
            case UInt8(ascii: ">"):
                if pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: ">") {
                    pos += 2
                    return .op(">>")
                }
                pos += 1
                return .op(">")
            case UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                pos += 1
                return .op(String(UnicodeScalar(c)))
            default:
                let start = pos
                while pos < bytes.count, !Self.isDelimiterOrSpace(bytes[pos]) { pos += 1 }
                if pos == start {
                    pos += 1
                    return .op(String(UnicodeScalar(c)))
                }
                let word = String(decoding: bytes[start..<pos], as: UTF8.self)
                if let d = Double(word), word.first.map({ "+-.0123456789".contains($0) }) == true { return .num(d) }
                switch word {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null": return .null
                default: return .op(word)
                }
            }
        }

        /// Reads a complete object, folding "N G R" references and attaching stream bodies.
        mutating func object(resolveStreams: ((Obj) -> Double?)?) throws -> Obj? {
            guard let t = try token() else { return nil }
            return try finish(t, resolveStreams: resolveStreams)
        }

        mutating func finish(_ t: Obj, resolveStreams: ((Obj) -> Double?)?) throws -> Obj {
            switch t {
            case .op("["):
                var arr: [Obj] = []
                while true {
                    guard let n = try token() else { break }
                    if case .op("]") = n { break }
                    arr.append(try finish(n, resolveStreams: resolveStreams))
                }
                return .array(Self.foldRefs(arr))
            case .op("<<"):
                var items: [Obj] = []
                while true {
                    guard let n = try token() else { break }
                    if case .op(">>") = n { break }
                    items.append(try finish(n, resolveStreams: resolveStreams))
                }
                items = Self.foldRefs(items)
                var d: [String: Obj] = [:]
                var i = 0
                while i + 1 < items.count {
                    if case .name(let k) = items[i] { d[k] = items[i + 1] }
                    i += 2
                }
                // A stream follows its dictionary.
                let save = pos
                skipSpace()
                if bytes[pos...].starts(with: Array("stream".utf8)) {
                    pos += 6
                    if pos < bytes.count, bytes[pos] == 0x0D { pos += 1 }
                    if pos < bytes.count, bytes[pos] == 0x0A { pos += 1 }
                    let start = pos
                    var length = -1
                    if let l = d["Length"] {
                        if case .num(let n) = l { length = Int(n) } else if let n = resolveStreams?(l) { length = Int(n) }
                    }
                    var end: Int
                    if length >= 0, start + length <= bytes.count,
                       Self.followsEndstream(bytes, start + length) {
                        end = start + length
                    } else {
                        end = Self.find(bytes, Array("endstream".utf8), from: start) ?? bytes.count
                        while end > start, bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D { end -= 1 }
                    }
                    pos = min(bytes.count, end)
                    return .stream(d, Data(bytes[start..<end]))
                }
                pos = save
                return .dict(d)
            default:
                return t
            }
        }

        static func followsEndstream(_ bytes: [UInt8], _ at: Int) -> Bool {
            var p = at
            while p < bytes.count, isSpace(bytes[p]) { p += 1 }
            return bytes[p...].starts(with: Array("endstream".utf8))
        }

        static func find(_ bytes: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
            guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
            var i = from
            while i <= bytes.count - needle.count {
                if bytes[i] == needle[0], bytes[i..<(i + needle.count)].elementsEqual(needle) { return i }
                i += 1
            }
            return nil
        }

        static func foldRefs(_ items: [Obj]) -> [Obj] {
            var out: [Obj] = []
            for item in items {
                if case .op("R") = item, out.count >= 2, case .num(let g) = out[out.count - 1], case .num(let n) = out[out.count - 2] {
                    out.removeLast(2)
                    out.append(.ref(Int(n), Int(g)))
                } else {
                    out.append(item)
                }
            }
            return out
        }
    }
}

struct Matrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    /// self applied first, then m.
    func concat(_ m: Matrix) -> Matrix {
        Matrix(a: a * m.a + b * m.c, b: a * m.b + b * m.d,
               c: c * m.a + d * m.c, d: c * m.b + d * m.d,
               e: e * m.a + f * m.c + m.e, f: e * m.b + f * m.d + m.f)
    }

    var plutovg: plutovg_matrix_t {
        plutovg_matrix_t(a: Float(a), b: Float(b), c: Float(c), d: Float(d), e: Float(e), f: Float(f))
    }

    init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    init?(_ values: [Double]) {
        guard values.count >= 6 else { return nil }
        self.init(a: values[0], b: values[1], c: values[2], d: values[3], e: values[4], f: values[5])
    }
}

extension PDFDocument {
    final class Renderer {
        typealias Obj = PDFDocument.Obj

        struct State {
            var ctm = Matrix()
            var fill: (Double, Double, Double) = (0, 0, 0)
            var stroke: (Double, Double, Double) = (0, 0, 0)
            var fillAlpha = 1.0
            var strokeAlpha = 1.0
            var lineWidth = 1.0
            var lineCap: Int32 = 0
            var lineJoin: Int32 = 0
            var miterLimit = 10.0
            var dash: [Double] = []
            var dashPhase = 0.0
            var fillSpace = "DeviceGray"
            var strokeSpace = "DeviceGray"
            var fillPattern: [String: Obj]?
            // Text state
            var charSpacing = 0.0
            var wordSpacing = 0.0
            var hScale = 1.0
            var leading = 0.0
            var rise = 0.0
            var font: [String: Obj]?
            var fontSize = 1.0
        }

        enum Seg {
            case move(Double, Double)
            case line(Double, Double)
            case cubic(Double, Double, Double, Double, Double, Double)
            case close
        }

        let doc: PDFDocument
        let canvas: OpaquePointer
        var state = State()
        var stack: [State] = []
        var path: [Seg] = []
        var current = (0.0, 0.0)
        var pendingClip: Int32?
        var textMatrix = Matrix()
        var lineMatrix = Matrix()
        var uncoloredGlyph = false

        init(doc: PDFDocument, canvas: OpaquePointer) {
            self.doc = doc
            self.canvas = canvas
        }

        func applyClipRect(x: Double, y: Double, w: Double, h: Double) {
            var m = state.ctm.plutovg
            plutovg_canvas_set_matrix(canvas, &m)
            plutovg_canvas_new_path(canvas)
            plutovg_canvas_rect(canvas, Float(x), Float(y), Float(w), Float(h))
            plutovg_canvas_clip(canvas)
        }

        func save() {
            stack.append(state)
            plutovg_canvas_save(canvas)
        }

        func restore() {
            guard let s = stack.popLast() else { return }
            state = s
            plutovg_canvas_restore(canvas)
        }

        func emitPath() {
            var m = state.ctm.plutovg
            plutovg_canvas_set_matrix(canvas, &m)
            plutovg_canvas_new_path(canvas)
            for s in path {
                switch s {
                case .move(let x, let y): plutovg_canvas_move_to(canvas, Float(x), Float(y))
                case .line(let x, let y): plutovg_canvas_line_to(canvas, Float(x), Float(y))
                case .cubic(let a, let b, let c, let d, let e, let f): plutovg_canvas_cubic_to(canvas, Float(a), Float(b), Float(c), Float(d), Float(e), Float(f))
                case .close: plutovg_canvas_close_path(canvas)
                }
            }
        }

        func setFillPaint() {
            let (r, g, b) = state.fill
            plutovg_canvas_set_rgba(canvas, Float(r), Float(g), Float(b), Float(state.fillAlpha))
        }

        func setStrokePaint() {
            let (r, g, b) = state.stroke
            plutovg_canvas_set_rgba(canvas, Float(r), Float(g), Float(b), Float(state.strokeAlpha))
            plutovg_canvas_set_line_width(canvas, Float(state.lineWidth))
            plutovg_canvas_set_line_cap(canvas, plutovg_line_cap_t(rawValue: UInt32(state.lineCap)))
            plutovg_canvas_set_line_join(canvas, plutovg_line_join_t(rawValue: UInt32(state.lineJoin)))
            plutovg_canvas_set_miter_limit(canvas, Float(state.miterLimit))
            if state.dash.isEmpty {
                plutovg_canvas_set_dash_array(canvas, nil, 0)
            } else {
                var d = state.dash.map { Float($0) }
                plutovg_canvas_set_dash(canvas, Float(state.dashPhase), &d, Int32(d.count))
            }
        }

        func paint(fill: Bool, stroke: Bool, evenOdd: Bool) {
            if fill || stroke { emitPath() }
            if fill {
                plutovg_canvas_set_fill_rule(canvas, evenOdd ? PLUTOVG_FILL_RULE_EVEN_ODD : PLUTOVG_FILL_RULE_NON_ZERO)
                if let pattern = state.fillPattern, fillWithPattern(pattern) {
                    // painted by the pattern
                } else {
                    setFillPaint()
                    plutovg_canvas_fill_preserve(canvas)
                }
            }
            if stroke {
                setStrokePaint()
                plutovg_canvas_stroke_preserve(canvas)
            }
            if let rule = pendingClip {
                emitPath()
                plutovg_canvas_set_fill_rule(canvas, rule == 1 ? PLUTOVG_FILL_RULE_EVEN_ODD : PLUTOVG_FILL_RULE_NON_ZERO)
                plutovg_canvas_clip(canvas)
                pendingClip = nil
            }
            plutovg_canvas_new_path(canvas)
            path.removeAll()
        }

        /// Shading patterns used as fill: clip to the path, then paint the shading.
        func fillWithPattern(_ pattern: [String: Obj]) -> Bool {
            guard Int(doc.resolve(pattern["PatternType"])?.num ?? 0) == 2, let shading = doc.dict(pattern["Shading"]) else { return false }
            plutovg_canvas_save(canvas)
            plutovg_canvas_clip_preserve(canvas)
            let m = (doc.resolve(pattern["Matrix"])?.array?.compactMap { doc.resolve($0)?.num }).flatMap(Matrix.init) ?? Matrix()
            paintShading(shading, matrix: m.concat(stack.first?.ctm ?? state.ctm))
            plutovg_canvas_restore(canvas)
            return true
        }

        func colorFromComponents(_ comps: [Double], space: String) -> (Double, Double, Double) {
            switch comps.count {
            case 1: return (comps[0], comps[0], comps[0])
            case 3: return (comps[0], comps[1], comps[2])
            case 4:
                let k = comps[3]
                return ((1 - comps[0]) * (1 - k), (1 - comps[1]) * (1 - k), (1 - comps[2]) * (1 - k))
            default: return (0, 0, 0)
            }
        }

        func components(of space: Obj?) -> Int {
            switch doc.resolve(space) {
            case .name(let n)?:
                switch n {
                case "DeviceRGB", "CalRGB", "RGB": return 3
                case "DeviceCMYK", "CMYK": return 4
                default: return 1
                }
            case .array(let a)?:
                guard let kind = doc.resolve(a.first)?.name else { return 1 }
                switch kind {
                case "ICCBased":
                    if a.count > 1, let d = doc.dict(a[1]), let n = doc.resolve(d["N"])?.num { return Int(n) }
                    return 3
                case "CalRGB", "Lab": return 3
                case "Indexed": return 1
                default: return 1
                }
            default: return 1
            }
        }

        // MARK: Shading

        func evalFunction(_ fn: Obj?, _ t: Double) -> [Double] {
            guard let f = doc.resolve(fn), let d = f.dict else { return [t] }
            switch Int(doc.resolve(d["FunctionType"])?.num ?? 2) {
            case 2:
                let c0 = (doc.resolve(d["C0"])?.array?.compactMap { doc.resolve($0)?.num }) ?? [0]
                let c1 = (doc.resolve(d["C1"])?.array?.compactMap { doc.resolve($0)?.num }) ?? [1]
                let n = doc.resolve(d["N"])?.num ?? 1
                let tn = pow(max(0, t), n)
                return zip(c0, c1).map { $0 + tn * ($1 - $0) }
            case 3:
                let fns = doc.resolve(d["Functions"])?.array ?? []
                let bounds = (doc.resolve(d["Bounds"])?.array?.compactMap { doc.resolve($0)?.num }) ?? []
                let encode = (doc.resolve(d["Encode"])?.array?.compactMap { doc.resolve($0)?.num }) ?? []
                let domain = (doc.resolve(d["Domain"])?.array?.compactMap { doc.resolve($0)?.num }) ?? [0, 1]
                var k = 0
                while k < bounds.count, t >= bounds[k] { k += 1 }
                guard k < fns.count else { return [t] }
                let lo = k == 0 ? domain[0] : bounds[k - 1]
                let hi = k == bounds.count ? (domain.count > 1 ? domain[1] : 1) : bounds[k]
                let e0 = encode.count > 2 * k ? encode[2 * k] : 0, e1 = encode.count > 2 * k + 1 ? encode[2 * k + 1] : 1
                let tt = hi > lo ? e0 + (t - lo) / (hi - lo) * (e1 - e0) : e0
                return evalFunction(fns[k], tt)
            case 0:
                // Sampled functions: approximate with endpoints of the sample table.
                guard case .stream(_, _) = f, let data = doc.streamData(f) else { return [t] }
                let size = Int((doc.resolve(d["Size"])?.array?.first.flatMap { doc.resolve($0)?.num }) ?? 2)
                let bps = Int(doc.resolve(d["BitsPerSample"])?.num ?? 8)
                let range = (doc.resolve(d["Range"])?.array?.compactMap { doc.resolve($0)?.num }) ?? [0, 1]
                let outs = range.count / 2
                guard bps == 8, size > 0, data.count >= size * outs else { return [t] }
                let idx = min(size - 1, max(0, Int((t * Double(size - 1)).rounded())))
                return (0..<outs).map { o in
                    let v = Double(data[data.startIndex + idx * outs + o]) / 255
                    return range[2 * o] + v * (range[2 * o + 1] - range[2 * o])
                }
            default:
                return [t]
            }
        }

        func paintShading(_ shading: [String: Obj], matrix: Matrix) {
            let type = Int(doc.resolve(shading["ShadingType"])?.num ?? 0)
            guard type == 2 || type == 3 else { return }
            let coords = (doc.resolve(shading["Coords"])?.array?.compactMap { doc.resolve($0)?.num }) ?? []
            let space = shading["ColorSpace"]
            let fn = shading["Function"]
            var stops: [plutovg_gradient_stop_t] = []
            let n = 16
            for i in 0...n {
                let t = Double(i) / Double(n)
                let rgb = colorFromComponents(evalFunction(fn, t), space: "")
                _ = space
                stops.append(plutovg_gradient_stop_t(offset: Float(t), color: plutovg_color_t(r: Float(rgb.0), g: Float(rgb.1), b: Float(rgb.2), a: Float(state.fillAlpha))))
            }
            var m = matrix.plutovg
            let ident = Matrix().plutovg
            var identity = ident
            plutovg_canvas_set_matrix(canvas, &identity)
            if type == 2, coords.count >= 4 {
                plutovg_canvas_set_linear_gradient(canvas, Float(coords[0]), Float(coords[1]), Float(coords[2]), Float(coords[3]), PLUTOVG_SPREAD_METHOD_PAD, &stops, Int32(stops.count), &m)
            } else if type == 3, coords.count >= 6 {
                plutovg_canvas_set_radial_gradient(canvas, Float(coords[3]), Float(coords[4]), Float(coords[5]), Float(coords[0]), Float(coords[1]), Float(coords[2]), PLUTOVG_SPREAD_METHOD_PAD, &stops, Int32(stops.count), &m)
            } else {
                return
            }
            plutovg_canvas_paint(canvas)
        }

        // MARK: Images

        func drawImage(_ xobj: Obj, isMaskDepth: Int = 0) {
            guard case .stream(let d, let raw) = xobj else { return }
            let w = Int(doc.resolve(d["Width"])?.num ?? 0), h = Int(doc.resolve(d["Height"])?.num ?? 0)
            guard w > 0, h > 0, w * h < 1 << 26 else { return }
            var filters: [String] = []
            switch doc.resolve(d["Filter"]) {
            case .name(let n)?: filters = [n]
            case .array(let a)?: filters = a.compactMap { doc.resolve($0)?.name }
            default: break
            }
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            if filters.contains("DCTDecode") || filters.contains("DCT") {
                guard let bmp = try? Bitmap.decode(raw), bmp.width == w, bmp.height == h else { return }
                for i in 0..<(w * h) {
                    rgba[i * 4] = bmp.pixels[i * 4 + 2]
                    rgba[i * 4 + 1] = bmp.pixels[i * 4 + 1]
                    rgba[i * 4 + 2] = bmp.pixels[i * 4]
                }
            } else {
                guard let data = doc.streamData(xobj) else { return }
                let bytes = [UInt8](data)
                let bpc = Int(doc.resolve(d["BitsPerComponent"])?.num ?? 8)
                let isMask = (doc.resolve(d["ImageMask"]).map { if case .bool(true) = $0 { return true } else { return false } }) ?? false
                if isMask || bpc == 1 {
                    let rowBytes = (w + 7) / 8
                    for y in 0..<h {
                        for x in 0..<w {
                            let byte = y * rowBytes + x / 8
                            let bit = byte < bytes.count ? (bytes[byte] >> (7 - UInt8(x % 8))) & 1 : 0
                            let on = isMask ? bit == 0 : bit == 1
                            let i = (y * w + x) * 4
                            if isMask {
                                let (r, g, b) = state.fill
                                rgba[i] = UInt8(r * 255); rgba[i + 1] = UInt8(g * 255); rgba[i + 2] = UInt8(b * 255)
                                rgba[i + 3] = on ? 255 : 0
                            } else {
                                let v: UInt8 = on ? 255 : 0
                                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v
                            }
                        }
                    }
                } else {
                    guard bpc == 8 else { return }
                    var space = doc.resolve(d["ColorSpace"])
                    var palette: [UInt8]?
                    if case .array(let a)? = space, doc.resolve(a.first)?.name == "Indexed", a.count >= 4 {
                        space = doc.resolve(a[1])
                        switch doc.resolve(a[3]) {
                        case .str(let s)?: palette = s
                        case let s?: palette = doc.streamData(s).map { [UInt8]($0) }
                        default: break
                        }
                    }
                    let nc = components(of: space)
                    let srcComps = palette != nil ? 1 : nc
                    for i in 0..<(w * h) {
                        var c = [Double]()
                        if let palette {
                            let idx = i < bytes.count ? Int(bytes[i]) : 0
                            for k in 0..<nc { c.append(idx * nc + k < palette.count ? Double(palette[idx * nc + k]) / 255 : 0) }
                        } else {
                            for k in 0..<srcComps { c.append(i * srcComps + k < bytes.count ? Double(bytes[i * srcComps + k]) / 255 : 0) }
                        }
                        let rgb = colorFromComponents(c, space: "")
                        rgba[i * 4] = UInt8(max(0, min(255, rgb.0 * 255)))
                        rgba[i * 4 + 1] = UInt8(max(0, min(255, rgb.1 * 255)))
                        rgba[i * 4 + 2] = UInt8(max(0, min(255, rgb.2 * 255)))
                    }
                }
            }
            if let smask = doc.resolve(d["SMask"]), case .stream(let sd, _) = smask, let sdata = doc.streamData(smask) {
                let sw = Int(doc.resolve(sd["Width"])?.num ?? 0), sh = Int(doc.resolve(sd["Height"])?.num ?? 0)
                let sb = [UInt8](sdata)
                if sw > 0, sh > 0 {
                    for y in 0..<h {
                        for x in 0..<w {
                            let sx = x * sw / w, sy = y * sh / h
                            let v = sy * sw + sx < sb.count ? sb[sy * sw + sx] : 255
                            rgba[(y * w + x) * 4 + 3] = v
                        }
                    }
                }
            }
            // Premultiply into plutovg's native ARGB32 (B, G, R, A in memory).
            var argb = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                let a = UInt32(rgba[i * 4 + 3])
                argb[i * 4] = UInt8((UInt32(rgba[i * 4 + 2]) * a + 127) / 255)
                argb[i * 4 + 1] = UInt8((UInt32(rgba[i * 4 + 1]) * a + 127) / 255)
                argb[i * 4 + 2] = UInt8((UInt32(rgba[i * 4]) * a + 127) / 255)
                argb[i * 4 + 3] = UInt8(a)
            }
            argb.withUnsafeMutableBufferPointer { buf in
                guard let surface = plutovg_surface_create_for_data(buf.baseAddress, Int32(w), Int32(h), Int32(w * 4)) else { return }
                defer { plutovg_surface_destroy(surface) }
                var m = state.ctm.plutovg
                plutovg_canvas_set_matrix(canvas, &m)
                var tm = Matrix(a: 1 / Double(w), b: 0, c: 0, d: -1 / Double(h), e: 0, f: 1).plutovg
                plutovg_canvas_set_texture(canvas, surface, PLUTOVG_TEXTURE_TYPE_PLAIN, Float(state.fillAlpha), &tm)
                plutovg_canvas_new_path(canvas)
                plutovg_canvas_rect(canvas, 0, 0, 1, 1)
                plutovg_canvas_set_fill_rule(canvas, PLUTOVG_FILL_RULE_NON_ZERO)
                plutovg_canvas_fill(canvas)
            }
        }

        // MARK: Text (Type 3 fonts only)

        func showText(_ codes: [UInt8], resources: [String: Obj], depth: Int) {
            guard let font = state.font, doc.resolve(font["Subtype"])?.name == "Type3" else { return }
            let fm = (doc.resolve(font["FontMatrix"])?.array?.compactMap { doc.resolve($0)?.num }).flatMap(Matrix.init) ?? Matrix(a: 0.001, d: 0.001)
            let procs = doc.dict(font["CharProcs"]) ?? [:]
            let fontResources = doc.dict(font["Resources"]) ?? resources
            var names: [Int: String] = [:]
            if let enc = doc.dict(font["Encoding"]), let diffs = doc.resolve(enc["Differences"])?.array {
                var code = 0
                for item in diffs {
                    switch doc.resolve(item) {
                    case .num(let n)?: code = Int(n)
                    case .name(let n)?:
                        names[code] = n
                        code += 1
                    default: break
                    }
                }
            }
            let firstChar = Int(doc.resolve(font["FirstChar"])?.num ?? 0)
            let widths = (doc.resolve(font["Widths"])?.array?.compactMap { doc.resolve($0)?.num }) ?? []
            for code in codes {
                let c = Int(code)
                let trm = Matrix(a: state.fontSize * state.hScale, b: 0, c: 0, d: state.fontSize, e: 0, f: state.rise).concat(textMatrix).concat(state.ctm)
                if let name = names[c], let proc = doc.resolve(procs[name]), let data = doc.streamData(proc) {
                    save()
                    state.ctm = fm.concat(trm)
                    let saveUncolored = uncoloredGlyph
                    run(data, resources: fontResources, depth: depth + 1)
                    uncoloredGlyph = saveUncolored
                    restore()
                }
                let w0 = c - firstChar >= 0 && c - firstChar < widths.count ? widths[c - firstChar] : 0
                var tx = (w0 * fm.a * state.fontSize + state.charSpacing) * state.hScale
                if code == 32 { tx += state.wordSpacing * state.hScale }
                textMatrix = Matrix(e: tx).concat(textMatrix)
            }
        }

        // MARK: Interpreter

        func run(_ content: Data, resources: [String: Obj], depth: Int) {
            guard depth < 16 else { return }
            var lexer = Lexer(bytes: [UInt8](content), pos: 0)
            var operands: [Obj] = []
            func nums() -> [Double] { operands.compactMap { doc.resolve($0)?.num } }
            func n(_ i: Int) -> Double {
                let v = nums()
                return i < v.count ? v[i] : 0
            }
            while let tok = try? lexer.token() {
                guard case .op(let op) = tok else {
                    operands.append(tok)
                    continue
                }
                if op == "[" || op == "<<" {
                    if let v = try? lexer.finish(tok, resolveStreams: nil) { operands.append(v) }
                    continue
                }
                switch op {
                case "q": save()
                case "Q": restore()
                case "cm":
                    if let m = Matrix(nums()) { state.ctm = m.concat(state.ctm) }
                case "w": state.lineWidth = n(0)
                case "J": state.lineCap = Int32(n(0))
                case "j": state.lineJoin = Int32(n(0))
                case "M": state.miterLimit = n(0)
                case "d":
                    if let arr = operands.first.flatMap({ doc.resolve($0)?.array }) {
                        state.dash = arr.compactMap { doc.resolve($0)?.num }
                    }
                    state.dashPhase = operands.count > 1 ? (doc.resolve(operands[1])?.num ?? 0) : 0
                case "gs":
                    if let name = operands.last?.name, let gs = doc.dict(doc.dict(resources["ExtGState"])?[name]) {
                        if let ca = doc.resolve(gs["ca"])?.num { state.fillAlpha = ca }
                        if let ca = doc.resolve(gs["CA"])?.num { state.strokeAlpha = ca }
                        if let lw = doc.resolve(gs["LW"])?.num { state.lineWidth = lw }
                    }
                case "m":
                    current = (n(0), n(1))
                    path.append(.move(n(0), n(1)))
                case "l":
                    current = (n(0), n(1))
                    path.append(.line(n(0), n(1)))
                case "c":
                    path.append(.cubic(n(0), n(1), n(2), n(3), n(4), n(5)))
                    current = (n(4), n(5))
                case "v":
                    path.append(.cubic(current.0, current.1, n(0), n(1), n(2), n(3)))
                    current = (n(2), n(3))
                case "y":
                    path.append(.cubic(n(0), n(1), n(2), n(3), n(2), n(3)))
                    current = (n(2), n(3))
                case "h": path.append(.close)
                case "re":
                    let x = n(0), y = n(1), w = n(2), h = n(3)
                    path += [.move(x, y), .line(x + w, y), .line(x + w, y + h), .line(x, y + h), .close]
                    current = (x, y)
                case "S": paint(fill: false, stroke: true, evenOdd: false)
                case "s":
                    path.append(.close)
                    paint(fill: false, stroke: true, evenOdd: false)
                case "f", "F": paint(fill: true, stroke: false, evenOdd: false)
                case "f*": paint(fill: true, stroke: false, evenOdd: true)
                case "B": paint(fill: true, stroke: true, evenOdd: false)
                case "B*": paint(fill: true, stroke: true, evenOdd: true)
                case "b":
                    path.append(.close)
                    paint(fill: true, stroke: true, evenOdd: false)
                case "b*":
                    path.append(.close)
                    paint(fill: true, stroke: true, evenOdd: true)
                case "n": paint(fill: false, stroke: false, evenOdd: false)
                case "W": pendingClip = 0
                case "W*": pendingClip = 1
                case "CS": state.strokeSpace = operands.last?.name ?? "DeviceGray"
                case "cs":
                    state.fillSpace = operands.last?.name ?? "DeviceGray"
                    state.fillPattern = nil
                case "G": if !uncoloredGlyph { state.stroke = (n(0), n(0), n(0)) }
                case "g": if !uncoloredGlyph { state.fill = (n(0), n(0), n(0)); state.fillPattern = nil }
                case "RG": if !uncoloredGlyph { state.stroke = (n(0), n(1), n(2)) }
                case "rg": if !uncoloredGlyph { state.fill = (n(0), n(1), n(2)); state.fillPattern = nil }
                case "K": if !uncoloredGlyph { state.stroke = colorFromComponents(nums(), space: "") }
                case "k": if !uncoloredGlyph { state.fill = colorFromComponents(nums(), space: ""); state.fillPattern = nil }
                case "SC", "SCN":
                    if !uncoloredGlyph, !nums().isEmpty { state.stroke = colorFromComponents(nums(), space: state.strokeSpace) }
                case "sc", "scn":
                    if uncoloredGlyph { break }
                    if let name = operands.last?.name {
                        state.fillPattern = doc.dict(doc.dict(resources["Pattern"])?[name])
                    } else if !nums().isEmpty {
                        state.fill = colorFromComponents(nums(), space: state.fillSpace)
                        state.fillPattern = nil
                    }
                case "sh":
                    if let name = operands.last?.name, let sh = doc.dict(doc.dict(resources["Shading"])?[name]) {
                        plutovg_canvas_save(canvas)
                        paintShading(sh, matrix: state.ctm)
                        plutovg_canvas_restore(canvas)
                    }
                case "Do":
                    guard let name = operands.last?.name, let xo = doc.resolve(doc.dict(resources["XObject"])?[name]), case .stream(let d, _) = xo else { break }
                    if doc.resolve(d["Subtype"])?.name == "Form" {
                        save()
                        if let m = (doc.resolve(d["Matrix"])?.array?.compactMap { doc.resolve($0)?.num }).flatMap(Matrix.init) {
                            state.ctm = m.concat(state.ctm)
                        }
                        if let bbox = doc.resolve(d["BBox"])?.array?.compactMap({ doc.resolve($0)?.num }), bbox.count == 4 {
                            applyClipRect(x: bbox[0], y: bbox[1], w: bbox[2] - bbox[0], h: bbox[3] - bbox[1])
                        }
                        if let data = doc.streamData(xo) {
                            run(data, resources: doc.dict(d["Resources"]) ?? resources, depth: depth + 1)
                        }
                        restore()
                    } else if doc.resolve(d["Subtype"])?.name == "Image" {
                        drawImage(xo)
                    }
                case "BT":
                    textMatrix = Matrix()
                    lineMatrix = Matrix()
                case "ET": break
                case "Tf":
                    if operands.count >= 2, let name = operands[operands.count - 2].name {
                        state.font = doc.dict(doc.dict(resources["Font"])?[name])
                        state.fontSize = doc.resolve(operands.last)?.num ?? 1
                    }
                case "Tc": state.charSpacing = n(0)
                case "Tw": state.wordSpacing = n(0)
                case "Tz": state.hScale = n(0) / 100
                case "TL": state.leading = n(0)
                case "Ts": state.rise = n(0)
                case "Td":
                    lineMatrix = Matrix(e: n(0), f: n(1)).concat(lineMatrix)
                    textMatrix = lineMatrix
                case "TD":
                    state.leading = -n(1)
                    lineMatrix = Matrix(e: n(0), f: n(1)).concat(lineMatrix)
                    textMatrix = lineMatrix
                case "Tm":
                    if let m = Matrix(nums()) {
                        lineMatrix = m
                        textMatrix = m
                    }
                case "T*":
                    lineMatrix = Matrix(f: -state.leading).concat(lineMatrix)
                    textMatrix = lineMatrix
                case "Tj":
                    if case .str(let s)? = operands.last { showText(s, resources: resources, depth: depth) }
                case "'":
                    lineMatrix = Matrix(f: -state.leading).concat(lineMatrix)
                    textMatrix = lineMatrix
                    if case .str(let s)? = operands.last { showText(s, resources: resources, depth: depth) }
                case "\"":
                    state.wordSpacing = n(0)
                    state.charSpacing = n(1)
                    lineMatrix = Matrix(f: -state.leading).concat(lineMatrix)
                    textMatrix = lineMatrix
                    if case .str(let s)? = operands.last { showText(s, resources: resources, depth: depth) }
                case "TJ":
                    for item in operands.last?.array ?? [] {
                        switch item {
                        case .str(let s): showText(s, resources: resources, depth: depth)
                        case .num(let adj):
                            textMatrix = Matrix(e: -adj / 1000 * state.fontSize * state.hScale).concat(textMatrix)
                        default: break
                        }
                    }
                case "d0": break
                case "d1": uncoloredGlyph = true
                case "BI":
                    // Skip inline images.
                    while let t = try? lexer.token() { if case .op("EI") = t { break } }
                default: break
                }
                operands.removeAll()
            }
        }
    }
}
