import Foundation

/// A Linux-capable reimplementation of `xcstringstool compile`.
///
/// Produces the same per-locale `.strings` / `.stringsdict` property lists as
/// Xcode's `xcstringstool` (verified byte-for-byte against Xcode 26.5 output in
/// the text serialization format).
public struct XCStringsCompiler {
    public enum Format: String, Sendable {
        case stringsAndStringsdict
        case stringsdictOnly
    }

    public enum Serialization: String, Sendable {
        case text
        case binary
    }

    public struct Options: Sendable {
        public var format: Format = .stringsAndStringsdict
        public var serialization: Serialization = .text
        /// Only compile these languages. Empty means all languages in the catalog.
        public var languages: [String] = []
        /// Emit every key for the source language, even ones that would fall back to the key at runtime.
        public var forceBuildAllStrings = false

        public init() {}
    }

    /// A compile diagnostic, formatted the way `xcstringstool` prints it.
    public struct Diagnostic: Error, CustomStringConvertible, Sendable, Equatable {
        public var message: String
        public var language: String
        public var key: String
        public var variationPath: [String]

        public var description: String {
            var context = "\(language): \(key)"
            if !variationPath.isEmpty {
                context += "|==|" + variationPath.joined(separator: ".")
            }
            return "error: \(message) (\(context))"
        }
    }

    /// One output file: a path relative to the output directory and its property list.
    public struct Output: Sendable {
        public var relativePath: String
        public var plist: PlistValue

        public func data(_ serialization: Serialization) throws -> Data {
            switch serialization {
            case .text:
                return Data(plist.xmlPropertyList().utf8)
            case .binary:
                return try PropertyListSerialization.data(
                    fromPropertyList: plist.foundationValue, format: .binary, options: 0
                )
            }
        }
    }

    public struct Result: Sendable {
        public var outputs: [Output]
        public var diagnostics: [Diagnostic]
    }

    public let catalog: Catalog
    public let tableName: String
    public let options: Options

    public init(catalog: Catalog, tableName: String, options: Options = .init()) {
        self.catalog = catalog
        self.tableName = tableName
        self.options = options
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func compile() -> Result {
        var diagnostics: [Diagnostic] = []
        var outputs: [Output] = []

        // Spellings that differ only in case (`en-gb`, `en-GB`) compile into one lproj; the canonical spelling wins.
        var spellings: [String: Set<String>] = [:]
        spellings[Self.canonicalLanguage(catalog.sourceLanguage), default: []].insert(catalog.sourceLanguage)
        for entry in catalog.strings.values {
            for language in entry.localizations.keys {
                spellings[Self.canonicalLanguage(language), default: []].insert(language)
            }
        }
        if !options.languages.isEmpty {
            let wanted = Set(options.languages.map(Self.canonicalLanguage))
            spellings = spellings.filter { wanted.contains($0.key) }
        }

        for (language, variants) in spellings.sorted(by: { Self.literalLess($0.key, $1.key) }) {
            var strings: [(String, PlistValue)] = []
            var stringsdict: [(String, PlistValue)] = []
            let isSource = language == Self.canonicalLanguage(catalog.sourceLanguage)
            let lookupOrder = [language] + variants.filter { $0 != language }.sorted(by: Self.literalLess)

            for (key, entry) in catalog.strings {
                guard let localization = lookupOrder.lazy.compactMap({ entry.localizations[$0] }).first else {
                    if isSource && (options.forceBuildAllStrings || entry.isManuallyManaged) {
                        strings.append((key, .string(key)))
                    }
                    continue
                }

                var context = Context(language: language, key: key, diagnostics: [])
                let compiled = compileLocalization(localization, entry: entry, isSource: isSource, context: &context)
                diagnostics += context.diagnostics
                if let plain = compiled.plain {
                    if options.format == .stringsdictOnly {
                        stringsdict.append((key, .string(plain)))
                    } else {
                        strings.append((key, .string(plain)))
                    }
                }
                if let rule = compiled.rule {
                    stringsdict.append((key, rule))
                }
                if compiled.plain != nil, compiled.rule != nil, options.format == .stringsdictOnly {
                    diagnostics.append(Diagnostic(
                        message: "Fallback value must be written to .strings file, which is not possible in stringsdictOnly mode",
                        language: language, key: key, variationPath: ["device", "other"]
                    ))
                }
            }

            let directory = "\(language).lproj"
            if !strings.isEmpty {
                outputs.append(Output(relativePath: "\(directory)/\(tableName).strings", plist: .dict(strings)))
            }
            if !stringsdict.isEmpty {
                outputs.append(Output(relativePath: "\(directory)/\(tableName).stringsdict", plist: .dict(stringsdict)))
            }
        }

        return Result(outputs: outputs, diagnostics: diagnostics)
    }

    // MARK: - Localization compilation

    private struct Context {
        var language: String
        var key: String
        var diagnostics: [Diagnostic]

        mutating func error(_ message: String, _ path: [String] = []) {
            diagnostics.append(Diagnostic(message: message, language: language, key: key, variationPath: path))
        }
    }

    /// The result of compiling one localization: a plain `.strings` value, a `.stringsdict` rule, or both
    /// (device variations put the `other` fallback in `.strings` and the specific devices in `.stringsdict`).
    private struct Compiled {
        var plain: String?
        var rule: PlistValue?
    }

    private func compileLocalization(_ localization: Localization, entry: Entry, isSource: Bool, context: inout Context) -> Compiled {
        if let variations = localization.variations {
            return compileVariations(variations, substitutions: localization.substitutions, path: [], context: &context)
        }
        guard let unit = localization.stringUnit else { return Compiled() }

        for name in FormatString.substitutionReferences(in: unit.value) where localization.substitutions[name] == nil {
            context.error("Referencing undefined substitution '\(name)'")
        }
        // Any localization that defines substitutions goes to .stringsdict, even when none are referenced.
        if !localization.substitutions.isEmpty {
            let references = FormatString.substitutionReferences(in: unit.value).filter { localization.substitutions[$0] != nil }
            if references.isEmpty {
                return Compiled(rule: .string(unit.value))
            }
            return Compiled(rule: substitutionRule(unit.value, substitutions: localization.substitutions, context: &context))
        }

        // An extracted (not manually managed) source string in the "new" state falls back to the key at runtime.
        if isSource && unit.state == "new" && !entry.isManuallyManaged && !options.forceBuildAllStrings {
            return Compiled()
        }
        return Compiled(plain: unit.value)
    }

    private func compileVariations(
        _ variations: Variations,
        substitutions: [String: Substitution],
        path: [String],
        context: inout Context
    ) -> Compiled {
        switch variations {
        case .plural(let cases):
            for (category, node) in cases {
                checkNoSubstitutionReferences(node, substitutions: substitutions, path: path + ["plural", category], context: &context)
            }
            let plainCases = cases.compactMap { category, node -> (String, String)? in
                guard case .stringUnit(let unit) = node else { return nil }
                return (category, unit.value)
            }
            return Compiled(rule: pluralRule(plainCases, path: path, context: &context))

        case .device(let devices):
            var fallback: String?
            var specific: [(String, PlistValue)] = []
            for (device, node) in devices {
                let devicePath = path + ["device", device]
                switch node {
                case .stringUnit(let unit):
                    checkNoSubstitutionReferences(node, substitutions: substitutions, path: devicePath, context: &context)
                    if device == "other" {
                        fallback = unit.value
                    } else {
                        specific.append((device, .string(unit.value)))
                    }
                case .variations(let nested):
                    if device == "other" {
                        context.error("Fallback value cannot be further varied", devicePath)
                        continue
                    }
                    let compiled = compileVariations(nested, substitutions: substitutions, path: devicePath, context: &context)
                    if let rule = compiled.rule {
                        specific.append((device, rule))
                    }
                }
            }
            var result = Compiled(plain: fallback)
            if !specific.isEmpty {
                result.rule = .dict([("NSStringDeviceSpecificRuleType", .dict(specific))])
            }
            return result
        }
    }

    private func checkNoSubstitutionReferences(
        _ node: VariationNode,
        substitutions: [String: Substitution],
        path: [String],
        context: inout Context
    ) {
        guard case .stringUnit(let unit) = node else { return }
        for name in FormatString.substitutionReferences(in: unit.value) {
            if substitutions[name] != nil {
                context.error("Cannot reference substitution '\(name)' from here because it is not a plain string", path)
            } else {
                context.error("Referencing undefined substitution '\(name)'", path)
            }
        }
    }

    /// Builds `{NSStringLocalizedFormatKey: "%#@value@", value: {...}}` for a plural variation,
    /// inferring the plural argument and its type from the numeric format specifiers in the cases.
    private func pluralRule(_ cases: [(String, String)], path: [String], context: inout Context) -> PlistValue {
        var numeric: [(argument: Int, specifier: FormatString.Specifier)] = []
        for (_, value) in cases {
            for (argument, specifier) in FormatString.arguments(in: value) where specifier.isNumeric {
                numeric.append((argument, specifier))
            }
        }
        // Invalid groups still produce a rule so `--dry-run` (which doesn't validate) lists the same files as Xcode.
        if numeric.isEmpty {
            context.error(
                "Plural variation requires referencing the number in the string. "
                    + "To maintain grammatical correctness for strings that do not reference the number of items, "
                    + "use separate top-level strings for one and greater than one.",
                path
            )
        } else if Set(numeric.map(\.specifier.withoutPosition)).count > 1 {
            context.error("Cannot infer format specifier for string group because more than one numerical specifier was found", path)
        }
        let argument = numeric.map(\.argument).min() ?? 1

        var ruleEntries: [(String, PlistValue)] = [
            ("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")),
            ("NSStringFormatValueTypeKey", .string(numeric.first?.specifier.valueType ?? "lld")),
        ]
        for (category, value) in cases {
            ruleEntries.append((category, .string(argument == 1 ? value : FormatString.makePositional(value))))
        }
        let formatKey = argument == 1 ? "%#@value@" : "%\(argument)$#@value@"
        return .dict([
            ("NSStringLocalizedFormatKey", .string(formatKey)),
            ("value", .dict(ruleEntries)),
        ])
    }

    /// Builds a stringsdict rule for a plain string that references `%#@name@` substitutions.
    private func substitutionRule(_ value: String, substitutions: [String: Substitution], context: inout Context) -> PlistValue {
        let formatKey = FormatString.rewriteSubstitutionReferences(in: value) { name in
            substitutions[name]?.argNum
        }
        var entries: [(String, PlistValue)] = [("NSStringLocalizedFormatKey", .string(formatKey))]
        for name in FormatString.substitutionReferences(in: value) {
            guard let substitution = substitutions[name], !entries.contains(where: { $0.0 == name }) else { continue }
            var rule: [(String, PlistValue)] = [
                ("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")),
                ("NSStringFormatValueTypeKey", .string(substitution.formatSpecifier)),
            ]
            let argSpecifier = "%\(substitution.argNum)$\(substitution.formatSpecifier)"
            for (category, node) in substitution.plural {
                guard case .stringUnit(let unit) = node else { continue }
                rule.append((category, .string(unit.value.replacingOccurrences(of: "%arg", with: argSpecifier))))
            }
            entries.append((name, .dict(rule)))
        }
        return .dict(entries)
    }

    // MARK: - Helpers

    /// Orders strings by UTF-16 code units, the way CoreFoundation sorts property list dictionary keys.
    static func literalLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    /// Canonicalizes the casing of a BCP 47 language tag (`en-gb` -> `en-GB`, `zh-hant` -> `zh-Hant`).
    static func canonicalLanguage(_ language: String) -> String {
        let parts = language.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return language }
        var result = [parts[0].lowercased()]
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy(\.isLetter) {
                result.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
            } else if part.count == 2, part.allSatisfy(\.isLetter) {
                result.append(part.uppercased())
            } else {
                result.append(part)
            }
        }
        return result.joined(separator: "-")
    }
}

// MARK: - Catalog model

public struct Catalog: Sendable {
    public var sourceLanguage: String
    public var version: String
    public var strings: [String: Entry]

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError("The data couldn't be read because it isn't in the correct format.")
        }
        guard let sourceLanguage = root["sourceLanguage"] as? String else {
            throw CatalogError("Missing sourceLanguage")
        }
        self.sourceLanguage = sourceLanguage
        self.version = root["version"] as? String ?? "1.0"
        var strings: [String: Entry] = [:]
        for (key, value) in root["strings"] as? [String: Any] ?? [:] {
            strings[key] = try Entry(value as? [String: Any] ?? [:])
        }
        self.strings = strings
    }
}

public struct CatalogError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

public struct Entry: Sendable {
    public var comment: String?
    public var extractionState: String?
    public var shouldTranslate: Bool
    public var localizations: [String: Localization]

    init(_ json: [String: Any]) throws {
        comment = json["comment"] as? String
        extractionState = json["extractionState"] as? String
        shouldTranslate = json["shouldTranslate"] as? Bool ?? true
        var localizations: [String: Localization] = [:]
        for (language, value) in json["localizations"] as? [String: Any] ?? [:] {
            localizations[language] = try Localization(value as? [String: Any] ?? [:])
        }
        self.localizations = localizations
    }

    /// Manually managed keys are compiled even without a reviewed source-language value;
    /// extracted ones fall back to the key at runtime.
    var isManuallyManaged: Bool {
        switch extractionState {
        case "manual", "migrated", "pasted": true
        default: false
        }
    }
}

public struct StringUnit: Sendable {
    public var state: String?
    public var value: String

    init?(_ json: Any?) {
        guard let json = json as? [String: Any] else { return nil }
        state = json["state"] as? String
        value = json["value"] as? String ?? ""
    }
}

public struct Localization: Sendable {
    public var stringUnit: StringUnit?
    public var variations: Variations?
    public var substitutions: [String: Substitution]

    init(_ json: [String: Any]) throws {
        stringUnit = StringUnit(json["stringUnit"])
        variations = try Variations(json["variations"])
        var substitutions: [String: Substitution] = [:]
        for (name, value) in json["substitutions"] as? [String: Any] ?? [:] {
            substitutions[name] = try Substitution(value as? [String: Any] ?? [:])
        }
        self.substitutions = substitutions
    }
}

public indirect enum VariationNode: Sendable {
    case stringUnit(StringUnit)
    case variations(Variations)

    init?(_ json: Any?) throws {
        guard let json = json as? [String: Any] else { return nil }
        if let nested = try Variations(json["variations"]) {
            self = .variations(nested)
        } else if let unit = StringUnit(json["stringUnit"]) {
            self = .stringUnit(unit)
        } else {
            return nil
        }
    }
}

public enum Variations: Sendable {
    case plural([(String, VariationNode)])
    case device([(String, VariationNode)])

    init?(_ json: Any?) throws {
        guard let json = json as? [String: Any] else { return nil }
        func cases(_ value: Any?) throws -> [(String, VariationNode)] {
            let dict = value as? [String: Any] ?? [:]
            return try dict.keys.sorted(by: XCStringsCompiler.literalLess).compactMap { key in
                try VariationNode(dict[key]).map { (key, $0) }
            }
        }
        if let plural = json["plural"] {
            self = .plural(try cases(plural))
        } else if let device = json["device"] {
            self = .device(try cases(device))
        } else {
            return nil
        }
    }
}

public struct Substitution: Sendable {
    public var argNum: Int
    public var formatSpecifier: String
    public var plural: [(String, VariationNode)]

    init(_ json: [String: Any]) throws {
        argNum = (json["argNum"] as? NSNumber)?.intValue ?? 1
        formatSpecifier = json["formatSpecifier"] as? String ?? "lld"
        if case .plural(let cases)? = try Variations(json["variations"]) {
            plural = cases
        } else {
            plural = []
        }
    }
}

// MARK: - Format strings

enum FormatString {
    struct Specifier: Hashable {
        /// Explicit `N$` position, if any.
        var position: Int?
        var flags: String
        var width: String
        var precision: String
        var length: String
        var conversion: Character

        var isNumeric: Bool { "diouxXeEfFgGaA".contains(conversion) }
        var valueType: String { length + String(conversion) }
        var withoutPosition: String { flags + width + precision + length + String(conversion) }
    }

    enum Token {
        case literal(String)
        case percent
        case specifier(Specifier, text: String)
        case substitution(name: String, position: Int?, text: String)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func tokenize(_ string: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        let chars = Array(string)
        var i = 0
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while i < chars.count {
            guard chars[i] == "%" else { literal.append(chars[i]); i += 1; continue }
            let start = i
            var j = i + 1
            if j < chars.count, chars[j] == "%" {
                flush(); tokens.append(.percent); i = j + 1; continue
            }
            var digits = ""
            var k = j
            while k < chars.count, chars[k].isASCII, chars[k].isNumber { digits.append(chars[k]); k += 1 }
            var position: Int?
            if !digits.isEmpty, k < chars.count, chars[k] == "$" {
                position = Int(digits); j = k + 1
            }
            if j + 1 < chars.count, chars[j] == "#", chars[j + 1] == "@",
               let end = chars[(j + 2)...].firstIndex(of: "@") {
                flush()
                let name = String(chars[(j + 2)..<end])
                tokens.append(.substitution(name: name, position: position, text: String(chars[start...end])))
                i = end + 1
                continue
            }
            // A space flag is deliberately not accepted: Xcode reads "100% of" as literal text.
            var flags = ""
            while j < chars.count, "-+#0'".contains(chars[j]) { flags.append(chars[j]); j += 1 }
            var width = ""
            while j < chars.count, chars[j].isASCII, chars[j].isNumber || chars[j] == "*" { width.append(chars[j]); j += 1 }
            var precision = ""
            if j < chars.count, chars[j] == "." {
                precision.append("."); j += 1
                while j < chars.count, chars[j].isASCII, chars[j].isNumber || chars[j] == "*" { precision.append(chars[j]); j += 1 }
            }
            var length = ""
            for candidate in ["hh", "ll", "h", "l", "q", "L", "z", "t", "j"] {
                let c = Array(candidate)
                if j + c.count <= chars.count, Array(chars[j..<(j + c.count)]) == c {
                    length = candidate; j += c.count; break
                }
            }
            if j < chars.count, "diouxXeEfFgGaAcCsSp@".contains(chars[j]) {
                flush()
                let spec = Specifier(
                    position: position, flags: flags, width: width, precision: precision, length: length, conversion: chars[j]
                )
                tokens.append(.specifier(spec, text: String(chars[start...j])))
                i = j + 1
            } else {
                literal.append(chars[i]); i += 1
            }
        }
        flush()
        return tokens
    }

    /// The argument index each format specifier consumes, in order of appearance.
    static func arguments(in string: String) -> [(Int, Specifier)] {
        var next = 1
        var result: [(Int, Specifier)] = []
        for token in tokenize(string) {
            guard case .specifier(let spec, _) = token else { continue }
            let index = spec.position ?? next
            next = index + 1
            result.append((index, spec))
        }
        return result
    }

    static func substitutionReferences(in string: String) -> [String] {
        tokenize(string).compactMap {
            if case .substitution(let name, _, _) = $0 { return name }
            return nil
        }
    }

    /// Rewrites sequential specifiers (`%@`, `%lld`) to explicit positions (`%1$@`, `%2$lld`).
    static func makePositional(_ string: String) -> String {
        var next = 1
        var out = ""
        for token in tokenize(string) {
            switch token {
            case .literal(let text): out += text
            case .percent: out += "%%"
            case .substitution(_, _, let text): out += text
            case .specifier(let spec, let text):
                let index = spec.position ?? next
                next = index + 1
                out += spec.position == nil ? "%\(index)$" + text.dropFirst() : text
            }
        }
        return out
    }

    /// Numbers `%#@name@` references by their position among the string's arguments.
    static func makeSubstitutionsPositional(_ string: String) -> String {
        var next = 1
        var out = ""
        for token in tokenize(string) {
            switch token {
            case .literal(let text): out += text
            case .percent: out += "%%"
            case .specifier(let spec, let text):
                next = (spec.position ?? next) + 1
                out += text
            case .substitution(let name, let position, let text):
                if let position {
                    next = position + 1
                    out += text
                } else {
                    out += "%\(next)$#@\(name)@"
                    next += 1
                }
            }
        }
        return out
    }

    static func rewriteSubstitutionReferences(in string: String, argNum: (String) -> Int?) -> String {
        var out = ""
        for token in tokenize(string) {
            switch token {
            case .literal(let text): out += text
            case .percent: out += "%%"
            case .specifier(_, let text): out += text
            case .substitution(let name, let position, let text):
                if position == nil, let number = argNum(name) {
                    out += "%\(number)$#@\(name)@"
                } else {
                    out += text
                }
            }
        }
        return out
    }
}

// MARK: - Property list values

public indirect enum PlistValue: Sendable, Equatable {
    case string(String)
    /// Entries are written sorted by key, like CoreFoundation does.
    case dict([(String, PlistValue)])

    public static func == (lhs: PlistValue, rhs: PlistValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.dict(let a), .dict(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    var sortedEntries: [(String, PlistValue)] {
        guard case .dict(let entries) = self else { return [] }
        return entries.sorted { XCStringsCompiler.literalLess($0.0, $1.0) }
    }

    var foundationValue: Any {
        switch self {
        case .string(let s): return s
        case .dict(let entries):
            var dict: [String: Any] = [:]
            for (key, value) in entries { dict[key] = value.foundationValue }
            return dict
        }
    }

    /// Serializes as an XML property list formatted exactly like CoreFoundation's writer.
    public func xmlPropertyList() -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        append(to: &out, indent: 0)
        out += "</plist>\n"
        return out
    }

    private func append(to out: inout String, indent: Int) {
        let pad = String(repeating: "\t", count: indent)
        switch self {
        case .string(let s):
            out += "\(pad)<string>\(Self.escape(s))</string>\n"
        case .dict:
            let entries = sortedEntries
            if entries.isEmpty {
                out += "\(pad)<dict/>\n"
                return
            }
            out += "\(pad)<dict>\n"
            for (key, value) in entries {
                out += "\(pad)\t<key>\(Self.escape(key))</key>\n"
                value.append(to: &out, indent: indent + 1)
            }
            out += "\(pad)</dict>\n"
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
