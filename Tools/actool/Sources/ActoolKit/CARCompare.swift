import Foundation

/// Compares two CAR files structurally: names, rendition keys and the CSI fields CoreUI resolves assets by.
///
/// actool packs small images into atlases ("ZZZZPackedAsset" renditions plus internal links) and
/// compresses pixels with formats this tool can't decode, so pixels are compared on macOS with CoreUI
/// (see Scripts/carcheck.m); this checks everything else.
public struct CARComparison: CustomStringConvertible {
    public var facetsOnlyInReference: [String] = []
    public var facetsOnlyInCandidate: [String] = []
    public var renditionsOnlyInReference: [String] = []
    public var renditionsOnlyInCandidate: [String] = []
    public var fieldMismatches: [String] = []
    public var matchedRenditions = 0
    public var appearanceMismatch: String?

    public var isMatch: Bool {
        facetsOnlyInReference.isEmpty && facetsOnlyInCandidate.isEmpty && renditionsOnlyInReference.isEmpty
            && renditionsOnlyInCandidate.isEmpty && fieldMismatches.isEmpty && appearanceMismatch == nil
    }

    public var description: String {
        var lines = ["matched renditions: \(matchedRenditions)"]
        func list(_ title: String, _ items: [String]) {
            if !items.isEmpty { lines.append("\(title) (\(items.count)):\n  " + items.prefix(20).joined(separator: "\n  ")) }
        }
        list("facets only in reference", facetsOnlyInReference)
        list("facets only in candidate", facetsOnlyInCandidate)
        list("renditions only in reference", renditionsOnlyInReference)
        list("renditions only in candidate", renditionsOnlyInCandidate)
        list("field mismatches", fieldMismatches)
        if let a = appearanceMismatch { lines.append("appearances: \(a)") }
        return lines.joined(separator: "\n")
    }

    /// Fields that may legitimately differ, e.g. when a reference stores a raster as gray and the candidate as color.
    public struct Options {
        public var ignoredFacets: Set<String> = []
        public var ignorePixelFormat = false
        public init() {}
    }

    public static func compare(reference refData: Data, candidate candData: Data, options: Options = Options()) throws -> CARComparison {
        let ref = try CARReader(refData)
        let cand = try CARReader(candData)
        var result = CARComparison()
        let refNames = Set(ref.facets.keys).subtracting(options.ignoredFacets)
        let candNames = Set(cand.facets.keys).subtracting(options.ignoredFacets)
        result.facetsOnlyInReference = refNames.subtracting(candNames).sorted()
        result.facetsOnlyInCandidate = candNames.subtracting(refNames).sorted()
        if ref.appearances != cand.appearances {
            result.appearanceMismatch = "reference \(ref.appearances.sorted { $0.key < $1.key }) candidate \(cand.appearances.sorted { $0.key < $1.key })"
        }
        let refLocales = Dictionary(uniqueKeysWithValues: ref.localizations.map { ($0.value, $0.key) })
        let candLocales = Dictionary(uniqueKeysWithValues: cand.localizations.map { ($0.value, $0.key) })

        for name in refNames.intersection(candNames).sorted() {
            if ref.facets[name]?[.part] != cand.facets[name]?[.part] {
                result.fieldMismatches.append("\(name): facet part \(ref.facets[name]?[.part] ?? 0) vs \(cand.facets[name]?[.part] ?? 0)")
            }
            func keyString(_ r: CARReader.Rendition, locales: [UInt16: String]) -> String {
                r.key.filter { ![.identifier, .element, .dimension1].contains($0.key) && $0.value != 0 }
                    .sorted { $0.key < $1.key }
                    .map { $0.key == .localization ? "localization=\(locales[$0.value] ?? "?")" : "\($0.key.name)=\($0.value)" }
                    .joined(separator: " ")
            }
            var refByKey: [String: CARReader.Rendition] = [:]
            for r in ref.renditions(named: name) { refByKey[keyString(r, locales: refLocales)] = r }
            var candByKey: [String: CARReader.Rendition] = [:]
            for r in cand.renditions(named: name) { candByKey[keyString(r, locales: candLocales)] = r }
            for k in Set(refByKey.keys).subtracting(candByKey.keys).sorted() { result.renditionsOnlyInReference.append("\(name) [\(k)]") }
            for k in Set(candByKey.keys).subtracting(refByKey.keys).sorted() { result.renditionsOnlyInCandidate.append("\(name) [\(k)]") }
            for k in Set(refByKey.keys).intersection(candByKey.keys).sorted() {
                let a = refByKey[k]!, b = candByKey[k]!
                result.matchedRenditions += 1
                var diffs: [String] = []
                let layoutA = effectiveLayout(a), layoutB = effectiveLayout(b)
                if layoutA != layoutB { diffs.append("layout \(layoutA) vs \(layoutB)") }
                if !options.ignorePixelFormat, a.pixelFormat != b.pixelFormat { diffs.append("pixel format \(a.pixelFormat) vs \(b.pixelFormat)") }
                if (a.pixelFormat == "JPEG") == (b.pixelFormat == "JPEG"), a.pixelFormat != "JPEG", a.width != b.width || a.height != b.height {
                    diffs.append("size \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
                }
                if a.scaleFactor != b.scaleFactor { diffs.append("scale \(a.scaleFactor) vs \(b.scaleFactor)") }
                if a.flags != b.flags {
                    diffs.append("flags 0x\(String(a.flags, radix: 16)) vs 0x\(String(b.flags, radix: 16))")
                }
                if a.name != b.name, a.name != "CoreStructuredImage" || b.name != "CoreStructuredImage" { diffs.append("file name \(a.name) vs \(b.name)") }
                if let ca = a.color() {
                    if let cb = b.color() {
                        if ca.space != cb.space || ca.components != cb.components { diffs.append("color \(ca) vs \(cb)") }
                    } else {
                        diffs.append("color missing")
                    }
                }
                if a.payloadTag == "DWAR", a.pixelFormat == "DATA" || a.pixelFormat == "JPEG" || a.pixelFormat == "SVG ", let da = a.rawData() {
                    if a.layout == CSILayout.symbol {
                        // Symbol glyph SVGs are generated; compare the glyph metrics instead.
                        if a.info.first(where: { $0.type == CSIInfo.glyphMetrics })?.payload.count != b.info.first(where: { $0.type == CSIInfo.glyphMetrics })?.payload.count {
                            diffs.append("glyph metrics layout")
                        }
                    } else if b.rawData() != da {
                        diffs.append("raw data differs (\(da.count) vs \(b.rawData()?.count ?? -1) bytes)")
                    }
                }
                if let sa = slices(a), let sb = slices(b), sa != sb { diffs.append("slices \(sa) vs \(sb)") }
                if let ma = metrics(a), let mb = metrics(b), ma != mb { diffs.append("metrics \(ma) vs \(mb)") }
                if !diffs.isEmpty { result.fieldMismatches.append("\(name) [\(k)]: " + diffs.joined(separator: "; ")) }
            }
        }
        return result
    }

    /// Internal-link renditions (atlas references) carry the real layout in their reference info.
    static func effectiveLayout(_ r: CARReader.Rendition) -> UInt16 {
        guard r.layout == 1003, let ref = r.info.first(where: { $0.type == CSIInfo.reference }) else { return r.layout }
        var rd = ByteReader(ref.payload, offset: 24)
        return (try? rd.u16le()) ?? r.layout
    }

    static func slices(_ r: CARReader.Rendition) -> [UInt32]? {
        guard let s = r.info.first(where: { $0.type == CSIInfo.slices }) else { return nil }
        var rd = ByteReader(s.payload)
        var out: [UInt32] = []
        while let v = try? rd.u32le() { out.append(v) }
        return out
    }

    static func metrics(_ r: CARReader.Rendition) -> [UInt32]? {
        guard let s = r.info.first(where: { $0.type == CSIInfo.metrics }) else { return nil }
        var rd = ByteReader(s.payload)
        var out: [UInt32] = []
        while let v = try? rd.u32le() { out.append(v) }
        return out
    }
}
