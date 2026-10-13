import Foundation

/// Compiles SF Symbols templates (`.symbolset`) into vector glyph renditions.
///
/// Each "Weight-Size" group of the template becomes its own SVG, cropped to the glyph's painted bounds and
/// scaled from the typeset size to 17 points, plus metrics (baseline offset, cap height, margins).
extension CatalogCompiler {
    static let glyphWeights: [String: UInt16] = [
        "Ultralight": 1, "Thin": 2, "Light": 3, "Regular": 4, "Medium": 5, "Semibold": 6, "Bold": 7, "Heavy": 8, "Black": 9,
    ]
    static let glyphSizes: [String: UInt16] = ["S": 1, "M": 2, "L": 3]
    /// Glyph scale of small and large symbols relative to medium.
    static let glyphSizeScale: [UInt16: Double] = [1: 0.783_7, 2: 1, 3: 1.291_7]

    func compileSymbolSet(_ asset: Asset) throws {
        var produced = false
        for obj in (asset.contents["symbols"]?.array ?? []).compactMap(\.object) {
            guard let file = obj["filename"]?.string, let v = variant(of: obj, assetName: asset.name), allowedIdioms.contains(v.idiom) else { continue }
            let url = asset.directory.appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                diagnostics.append(Diagnostic(.error, "missing symbol file \(file)", item: asset.name))
                continue
            }
            let template = try SymbolTemplate(String(decoding: data, as: UTF8.self))
            for glyph in template.glyphs() {
                var k = key(asset.name, part: CARPart.symbol, variant: v, scale: 1)
                k[.glyphWeight] = glyph.weight
                k[.glyphSize] = glyph.size
                k[.deploymentTarget] = 5
                var r = CSIRendition(key: k, layout: CSILayout.symbol, name: file, payload: CSIPayload.raw(Data(glyph.svg.utf8), compress: true))
                r.flags = 0x4
                r.scaleFactor = 100
                r.pixelFormat = fourCC("SVG ")
                var metrics = ByteWriter()
                metrics.u32le(7)
                metrics.u32le(17)
                metrics.f32le(Float(glyph.baselineOffset))
                metrics.f32le(Float(glyph.capHeight))
                metrics.f32le(Float(template.templateVersion))
                metrics.f32le(Float(glyph.leftInset))
                metrics.f32le(Float(glyph.verticalInset))
                metrics.f32le(Float(glyph.rightInset))
                metrics.f32le(Float(glyph.verticalInset))
                metrics.f32le(0)
                var info = ByteWriter()
                info.u32le(1)
                info.u32le(0)
                info.u32le(3)
                r.info = [CSIInfoBuilder.composition(opacity: 1), CSIInfoBuilder.bitmapInfo(), (CSIInfo.glyphMetrics, metrics.data), (CSIInfo.glyphInfo, info.data)]
                writer.renditions.append(r)
                produced = true
            }
        }
        if produced { addFacet(asset.name, part: CARPart.symbol, extra: [.deploymentTarget: 5]) }
    }
}

/// A parsed SF Symbols template SVG.
struct SymbolTemplate {
    struct Element {
        var name: String
        var attributes: [(String, String)]
        var children: [Element] = []
        var text = ""

        func attr(_ k: String) -> String? { attributes.first { $0.0 == k }?.1 }
    }

    struct Glyph {
        var weight: UInt16
        var size: UInt16
        var svg: String
        var baselineOffset: Double
        var capHeight: Double
        var leftInset: Double
        var rightInset: Double
        var verticalInset: Double
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self {
            case .malformed(let m): return "symbol template: \(m)"
            }
        }
    }

    let root: Element
    var styles: [(selector: String, properties: [(String, String)])] = []
    var typesetPoints = 100.0
    var templateVersion = 7.0

    init(_ text: String) throws {
        var parser = XMLLite(text)
        guard let r = parser.parseDocument() else { throw Error.malformed("not an SVG document") }
        root = r
        if let style = Self.find(root, where: { $0.name == "style" }) {
            styles = Self.parseCSS(style.text)
        }
        if let m = text.range(of: "Typeset at "), let end = text[m.upperBound...].range(of: " points") {
            typesetPoints = Double(text[m.upperBound..<end.lowerBound]) ?? 100
        }
        if let m = text.range(of: "Template v."), let end = text[m.upperBound...].firstIndex(of: "<") {
            templateVersion = Double(text[m.upperBound..<end]) ?? 7
        }
    }

    static func find(_ e: Element, where pred: (Element) -> Bool) -> Element? {
        if pred(e) { return e }
        for c in e.children { if let f = find(c, where: pred) { return f } }
        return nil
    }

    static func all(_ e: Element, where pred: (Element) -> Bool) -> [Element] {
        var out: [Element] = []
        if pred(e) { out.append(e) }
        for c in e.children { out += all(c, where: pred) }
        return out
    }

    static func parseCSS(_ css: String) -> [(String, [(String, String)])] {
        var out: [(String, [(String, String)])] = []
        var rest = Substring(css)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let selector = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = rest[rest.index(after: open)..<close]
            var props: [(String, String)] = []
            for decl in body.split(separator: ";") {
                let parts = decl.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    props.append((parts[0].trimmingCharacters(in: .whitespacesAndNewlines), parts[1].trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            out.append((selector, props))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    func guide(_ id: String) -> Element? { Self.find(root, where: { $0.attr("id") == id }) }

    static func translate(_ transform: String?) -> (Double, Double) {
        guard let t = transform, let open = t.firstIndex(of: "("), let close = t.firstIndex(of: ")") else { return (0, 0) }
        let nums = t[t.index(after: open)..<close].split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        if t.hasPrefix("matrix"), nums.count == 6 { return (nums[4], nums[5]) }
        if t.hasPrefix("translate"), nums.count >= 1 { return (nums[0], nums.count > 1 ? nums[1] : 0) }
        return (0, 0)
    }

    func glyphs() -> [Glyph] {
        guard let symbols = guide("Symbols") else { return [] }
        var groups: [(weight: UInt16, size: UInt16, name: String, element: Element)] = []
        for g in symbols.children where g.name == "g" {
            guard let id = g.attr("id") else { continue }
            let parts = id.split(separator: "-").map(String.init)
            guard parts.count == 2, let w = CatalogCompiler.glyphWeights[parts[0]], let s = CatalogCompiler.glyphSizes[parts[1]] else { continue }
            groups.append((w, s, id, g))
        }
        var result: [Glyph] = []
        for g in groups {
            if let glyph = makeGlyph(g.element, name: g.name, weight: g.weight, size: g.size, sizeScale: 1) { result.append(glyph) }
        }
        // Templates that only draw small glyphs get a medium one scaled up from Regular-S, as actool emits.
        if !groups.contains(where: { $0.size == 2 }), let regular = groups.first(where: { $0.weight == 4 && $0.size == 1 }) ?? groups.first {
            let scale = (CatalogCompiler.glyphSizeScale[2] ?? 1) / (CatalogCompiler.glyphSizeScale[regular.size] ?? 1)
            if let glyph = makeGlyph(regular.element, name: regular.name, weight: 5, size: 2, sizeScale: scale, guideSize: "M") { result.append(glyph) }
        }
        return result
    }

    func makeGlyph(_ group: Element, name: String, weight: UInt16, size: UInt16, sizeScale: Double, guideSize: String? = nil) -> Glyph? {
        let sizeLetter = guideSize ?? String(name.split(separator: "-").last ?? "S")
        let (gx, gy) = Self.translate(group.attr("transform"))
        let baseline = Double(guide("Baseline-\(sizeLetter)")?.attr("y1") ?? "") ?? gy
        let capline = Double(guide("Capline-\(sizeLetter)")?.attr("y1") ?? "") ?? (baseline - 70)
        let leftMargin = (Double(guide("left-margin-\(name)")?.attr("x1") ?? "") ?? gx) - gx
        var rightMarginOpt = Double(guide("right-margin-\(name)")?.attr("x1") ?? "").map { $0 - gx }
        let s = 17 / typesetPoints
        // Scaled sizes grow around a point slightly below the baseline, as actool's medium glyphs do.
        let yOffset = sizeScale == 1 ? 0 : (1 - sizeScale) * 0.085_02 * (baseline - capline)
        let paths = Self.all(group, where: { $0.name == "path" })
        guard !paths.isEmpty else { return nil }

        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var body = ""
        for p in paths {
            guard let d = p.attr("d") else { continue }
            let classes = (p.attr("class") ?? "").split(separator: " ").map(String.init)
            var inline: [(String, String)] = []
            var keptClasses: [String] = []
            for c in classes {
                if c.hasPrefix("monochrome-") || c.hasPrefix("hierarchical-") || c.hasPrefix("multicolor-") || c.hasPrefix("palette-") {
                    keptClasses.append(c)
                } else if let rule = styles.first(where: { $0.selector == "." + c }) {
                    inline += rule.properties
                }
            }
            var strokeWidth = 0.0
            if let sw = inline.first(where: { $0.0 == "stroke-width" }), let w = Double(sw.1), inline.contains(where: { $0.0 == "stroke" && $0.1 != "none" }) {
                strokeWidth = w
            }
            let pathData = sizeScale == 1 ? d : SVGPathBounds.scaled(d, by: sizeScale, yOffset: yOffset)
            if let b = SVGPathBounds.bounds(pathData) {
                let pad = strokeWidth * sizeScale / 2
                minX = min(minX, b.minX - pad)
                minY = min(minY, b.minY - pad)
                maxX = max(maxX, b.maxX + pad)
                maxY = max(maxY, b.maxY + pad)
            }
            var attrs = "class=\"\(keptClasses.joined(separator: " "))\" d=\"\(pathData)\""
            for (k, v) in inline.sorted(by: { $0.0 < $1.0 }) {
                let value = k == "stroke-width" ? Self.fmt((Double(v) ?? 0) * s * sizeScale) : v
                attrs += " \(k)=\"\(value)\""
            }
            body += "<path \(attrs)/>"
        }
        guard minX.isFinite else { return nil }
        if rightMarginOpt == nil { rightMarginOpt = maxX + (minX - leftMargin) }
        let rightMargin = rightMarginOpt! * sizeScale
        let w = (maxX - minX) * s, h = (maxY - minY) * s
        let tx = -minX * s, ty = -minY * s
        var css = ""
        for rule in styles {
            let sel = rule.selector
            guard sel.hasPrefix("."), !sel.contains("SFSymbolsPreview") else { continue }
            let name = String(sel.dropFirst())
            guard name == "defaults" || name.hasPrefix("monochrome-") || name.hasPrefix("hierarchical-") || name.hasPrefix("multicolor-") || name.hasPrefix("palette-") else { continue }
            css += ".\(name){" + rule.properties.sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1);" }.joined() + "}"
        }
        let svg = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg version=\"1.1\" viewBox=\"0 0 \(Self.fmt(w)) \(Self.fmt(h))\"><defs><style>\(css)</style></defs><g id=\"s\" transform=\"matrix(\(Self.fmt(s)) 0 0 \(Self.fmt(s)) \(Self.fmt(tx)) \(Self.fmt(ty)))\">\(body)</g></svg>\n"
        let leftInset = (minX - leftMargin * sizeScale) * s
        let rightInset = (rightMargin - maxX) * s
        // Vertical alignment inset: a fixed fraction of the cap height, matching actool's output.
        return Glyph(weight: weight, size: size, svg: svg,
                     baselineOffset: maxY * s,
                     capHeight: (baseline - capline) * s,
                     leftInset: leftInset, rightInset: rightInset,
                     verticalInset: 0.097_02 * (baseline - capline) * sizeScale * s)
    }

    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.6g", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}

/// Bounds and scaling for SVG path data.
enum SVGPathBounds {
    static func tokens(_ d: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(c))
            } else if c == "," || c == " " || c == "\n" || c == "\t" || c == "\r" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else if c == "-" && !cur.isEmpty && !(cur.last == "e" || cur.last == "E") {
                out.append(cur)
                cur = "-"
            } else if c == "." && cur.contains(".") && !(cur.contains("e") || cur.contains("E")) {
                out.append(cur)
                cur = "."
            } else {
                cur.append(c)
            }
            i += 1
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Bounds of the path's points and control points (conservative for curves).
    static func bounds(_ d: String) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let toks = tokens(d)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0
        var cmd: Character = "M"
        var i = 0
        func add(_ px: Double, _ py: Double) {
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
        }
        func num() -> Double? {
            guard i < toks.count, let v = Double(toks[i]) else { return nil }
            i += 1
            return v
        }
        var lastControl: (Double, Double)?
        var curvePoints: [(Double, Double, Double, Double, Double, Double, Double, Double)] = []
        while i < toks.count {
            if let c = toks[i].first, toks[i].count == 1, c.isLetter {
                cmd = c
                i += 1
                if c == "Z" || c == "z" {
                    x = startX; y = startY
                    continue
                }
            }
            let rel = cmd.isLowercase
            switch cmd.uppercased() {
            case "M", "L", "T":
                guard let a = num(), let b = num() else { i += 1; continue }
                x = rel ? x + a : a; y = rel ? y + b : b
                if cmd.uppercased() == "M" { startX = x; startY = y; cmd = rel ? "l" : "L" }
                add(x, y)
                lastControl = nil
            case "H":
                guard let a = num() else { i += 1; continue }
                x = rel ? x + a : a
                add(x, y)
            case "V":
                guard let b = num() else { i += 1; continue }
                y = rel ? y + b : b
                add(x, y)
            case "C":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x3 = num(), let y3 = num() else { i += 1; continue }
                let p1 = rel ? (x + x1, y + y1) : (x1, y1), p2 = rel ? (x + x2, y + y2) : (x2, y2), p3 = rel ? (x + x3, y + y3) : (x3, y3)
                curvePoints.append((x, y, p1.0, p1.1, p2.0, p2.1, p3.0, p3.1))
                x = p3.0; y = p3.1
                lastControl = p2
                add(x, y)
            case "S":
                guard let x2 = num(), let y2 = num(), let x3 = num(), let y3 = num() else { i += 1; continue }
                let p1 = lastControl.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y)
                let p2 = rel ? (x + x2, y + y2) : (x2, y2), p3 = rel ? (x + x3, y + y3) : (x3, y3)
                curvePoints.append((x, y, p1.0, p1.1, p2.0, p2.1, p3.0, p3.1))
                x = p3.0; y = p3.1
                lastControl = p2
                add(x, y)
            case "Q":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num() else { i += 1; continue }
                let p1 = rel ? (x + x1, y + y1) : (x1, y1), p2 = rel ? (x + x2, y + y2) : (x2, y2)
                let c1 = (x + 2.0 / 3.0 * (p1.0 - x), y + 2.0 / 3.0 * (p1.1 - y)), c2 = (p2.0 + 2.0 / 3.0 * (p1.0 - p2.0), p2.1 + 2.0 / 3.0 * (p1.1 - p2.1))
                curvePoints.append((x, y, c1.0, c1.1, c2.0, c2.1, p2.0, p2.1))
                x = p2.0; y = p2.1
                add(x, y)
            case "A":
                guard let rx0 = num(), let ry0 = num(), let rot = num(), let large = num(), let sweep = num(), let a = num(), let b = num() else { i += 1; continue }
                let x2 = rel ? x + a : a, y2 = rel ? y + b : b
                for p in arcPoints(x1: x, y1: y, rx: rx0, ry: ry0, rotation: rot, large: large != 0, sweep: sweep != 0, x2: x2, y2: y2) { add(p.0, p.1) }
                x = x2; y = y2
                add(x, y)
            default:
                i += 1
            }
        }
        // Tight bounds for cubic segments: sample each curve.
        for c in curvePoints {
            for k in 1..<16 {
                let t = Double(k) / 16, mt = 1 - t
                let px = mt * mt * mt * c.0 + 3 * mt * mt * t * c.2 + 3 * mt * t * t * c.4 + t * t * t * c.6
                let py = mt * mt * mt * c.1 + 3 * mt * mt * t * c.3 + 3 * mt * t * t * c.5 + t * t * t * c.7
                add(px, py)
            }
            // Refine extrema analytically.
            for (a, b, cc, dd, isX) in [(c.0, c.2, c.4, c.6, true), (c.1, c.3, c.5, c.7, false)] {
                let qa = -a + 3 * b - 3 * cc + dd, qb = 2 * (a - 2 * b + cc), qc = b - a
                var roots: [Double] = []
                if abs(qa) < 1e-12 {
                    if abs(qb) > 1e-12 { roots.append(-qc / qb) }
                } else {
                    let disc = qb * qb - 4 * qa * qc
                    if disc >= 0 { roots += [(-qb + disc.squareRoot()) / (2 * qa), (-qb - disc.squareRoot()) / (2 * qa)] }
                }
                for t in roots where t > 0 && t < 1 {
                    let mt = 1 - t
                    let v = mt * mt * mt * a + 3 * mt * mt * t * b + 3 * mt * t * t * cc + t * t * t * dd
                    if isX { minX = min(minX, v); maxX = max(maxX, v) } else { minY = min(minY, v); maxY = max(maxY, v) }
                }
            }
        }
        guard minX.isFinite else { return nil }
        return (minX, minY, maxX, maxY)
    }

    /// Points along an SVG elliptical arc (endpoint parameterization, SVG 1.1 appendix F.6).
    static func arcPoints(x1: Double, y1: Double, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool, x2: Double, y2: Double) -> [(Double, Double)] {
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 || (x1 == x2 && y1 == y2) { return [(x2, y2)] }
        let phi = rotation * .pi / 180, c = cos(phi), sn = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let x1p = c * dx + sn * dy, y1p = -sn * dx + c * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = c * cxp - sn * cyp + (x1 + x2) / 2, cy = sn * cxp + c * cyp + (y1 + y2) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        var pts: [(Double, Double)] = []
        let steps = 48
        for k in 0...steps {
            let t = theta1 + delta * Double(k) / Double(steps)
            let px = rx * cos(t), py = ry * sin(t)
            pts.append((c * px - sn * py + cx, sn * px + c * py + cy))
        }
        return pts
    }

    /// Maps every point (x, y) of path data to (x * factor, y * factor + yOffset); arc flags and angles are kept.
    static func scaled(_ d: String, by factor: Double, yOffset: Double = 0) -> String {
        let toks = tokens(d)
        var out: [String] = []
        var cmd: Character = "M"
        var argIndex = 0
        for t in toks {
            if let c = t.first, t.count == 1, c.isLetter {
                cmd = c
                argIndex = 0
                out.append(t)
                continue
            }
            guard let v = Double(t) else { out.append(t); continue }
            let absolute = cmd.isUppercase
            var value = v
            switch cmd.uppercased() {
            case "H": value = v * factor
            case "V": value = v * factor + (absolute ? yOffset : 0)
            case "A":
                let k = argIndex % 7
                if k == 0 || k == 1 || k == 5 { value = v * factor }
                if k == 6 { value = v * factor + (absolute ? yOffset : 0) }
            default:
                value = v * factor + (argIndex % 2 == 1 && absolute ? yOffset : 0)
            }
            argIndex += 1
            out.append(SymbolTemplate.fmt(value))
        }
        var s = ""
        for (i, t) in out.enumerated() {
            if i > 0, !(t.first?.isLetter ?? false), !(out[i - 1].first?.isLetter ?? false), !t.hasPrefix("-") { s += " " }
            s += t
        }
        return s
    }
}

/// A minimal XML reader for SVG templates: elements, attributes and text.
struct XMLLite {
    let chars: [Character]
    var i = 0

    init(_ text: String) { chars = Array(text) }

    mutating func parseDocument() -> SymbolTemplate.Element? {
        var stack: [SymbolTemplate.Element] = [SymbolTemplate.Element(name: "#document", attributes: [])]
        while i < chars.count {
            if chars[i] == "<" {
                if match("<!--") { skip(to: "-->"); continue }
                if match("<?") { skip(to: "?>"); continue }
                if match("<![CDATA[") {
                    let start = i
                    skip(to: "]]>")
                    stack[stack.count - 1].text += String(chars[start..<max(start, i - 3)])
                    continue
                }
                if match("<!") { skipDoctype(); continue }
                if match("</") {
                    while i < chars.count, chars[i] != ">" { i += 1 }
                    i += 1
                    if stack.count > 1 {
                        let done = stack.removeLast()
                        stack[stack.count - 1].children.append(done)
                    }
                    continue
                }
                i += 1
                var name = ""
                while i < chars.count, !chars[i].isWhitespace, chars[i] != ">", chars[i] != "/" { name.append(chars[i]); i += 1 }
                var attrs: [(String, String)] = []
                var selfClosing = false
                while i < chars.count {
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    if i >= chars.count { break }
                    if chars[i] == "/" { selfClosing = true; i += 1; continue }
                    if chars[i] == ">" { i += 1; break }
                    var key = ""
                    while i < chars.count, chars[i] != "=", !chars[i].isWhitespace, chars[i] != ">", chars[i] != "/" { key.append(chars[i]); i += 1 }
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    var value = ""
                    if i < chars.count, chars[i] == "=" {
                        i += 1
                        while i < chars.count, chars[i].isWhitespace { i += 1 }
                        if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                            let q = chars[i]
                            i += 1
                            while i < chars.count, chars[i] != q { value.append(chars[i]); i += 1 }
                            i += 1
                        }
                    }
                    attrs.append((key, Self.unescape(value)))
                }
                let el = SymbolTemplate.Element(name: name, attributes: attrs)
                if selfClosing {
                    stack[stack.count - 1].children.append(el)
                } else {
                    stack.append(el)
                }
            } else {
                stack[stack.count - 1].text.append(chars[i])
                i += 1
            }
        }
        while stack.count > 1 {
            let done = stack.removeLast()
            stack[stack.count - 1].children.append(done)
        }
        return stack.first?.children.first { $0.name == "svg" }
    }

    mutating func match(_ s: String) -> Bool {
        let a = Array(s)
        guard i + a.count <= chars.count, Array(chars[i..<(i + a.count)]) == a else { return false }
        i += a.count
        return true
    }

    mutating func skip(to s: String) {
        let a = Array(s)
        while i + a.count <= chars.count {
            if Array(chars[i..<(i + a.count)]) == a { i += a.count; return }
            i += 1
        }
        i = chars.count
    }

    mutating func skipDoctype() {
        var depth = 0
        while i < chars.count {
            if chars[i] == "[" { depth += 1 }
            if chars[i] == "]" { depth -= 1 }
            if chars[i] == ">" && depth <= 0 { i += 1; return }
            i += 1
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
