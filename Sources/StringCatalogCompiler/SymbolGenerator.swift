import Foundation

/// Reimplements `xcstringstool generate-symbols --language swift`: a `LocalizedStringResource` accessor for
/// every manually managed key in a String Catalog. Matches Xcode 26.5's output byte for byte.
public struct SymbolGenerator {
    public struct Diagnostic: Error, CustomStringConvertible, Sendable, Equatable {
        public var message: String
        public var key: String
        public var description: String { "error: \(message) (allLocales: \(key))" }
    }

    public let catalog: Catalog
    public let tableName: String

    public init(catalog: Catalog, tableName: String) {
        self.catalog = catalog
        self.tableName = tableName
    }

    public var outputFileName: String { "GeneratedStringSymbols_\(tableName).swift" }

    /// Returns the Swift source (empty when the catalog has no eligible strings) and any per-key errors.
    /// Keys with errors are left out, but the file is still produced.
    public func generate() -> (source: String, diagnostics: [Diagnostic]) {
        var diagnostics: [Diagnostic] = []
        let keys = catalog.strings.keys
            .filter { catalog.strings[$0]?.extractionState == "manual" }
            .sorted(by: XCStringsCompiler.literalLess)

        struct Candidate {
            var key: String
            var name: String
            var entry: Entry
        }
        var candidates: [Candidate] = []
        for key in keys {
            let entry = catalog.strings[key]!
            let name = Self.symbolName(for: key)
            if name.isEmpty {
                diagnostics.append(Diagnostic(message: "Unable to derive a symbol name from this key.", key: key))
            } else if Self.reservedNames.contains(name.lowercased()) {
                diagnostics.append(Diagnostic(
                    message: "This key is too close to a reserved keyword in Swift. Please rename the key.",
                    key: key
                ))
            } else {
                candidates.append(Candidate(key: key, name: name, entry: entry))
            }
        }

        let byName = Dictionary(grouping: candidates, by: \.name)
        var members: [String] = []
        for candidate in candidates {
            let clashes = byName[candidate.name]!.map(\.key).filter { $0 != candidate.key }.sorted(by: XCStringsCompiler.literalLess)
            if !clashes.isEmpty {
                let others = clashes.map { "“\($0)”" }.joined(separator: " and ")
                diagnostics.append(Diagnostic(
                    message: "This string key would generate the same symbol as \(others). "
                        + "Please change the key or disable symbol generation for this string.",
                    key: candidate.key
                ))
                continue
            }
            switch arguments(for: candidate.entry) {
            case .failure(let error):
                diagnostics.append(Diagnostic(message: error.message, key: candidate.key))
            case .success(let args):
                members.append(member(key: candidate.key, name: candidate.name, comment: candidate.entry.comment, arguments: args))
            }
        }

        guard !members.isEmpty else { return ("", diagnostics) }
        let source = header + members.joined(separator: "\n\n") + "\n}"
        return (source, diagnostics)
    }

    // MARK: - Output

    // The generated code must match Xcode's byte for byte, so its long lines stay as they are.
    // swiftlint:disable line_length
    private var header: String {
        // The banner's first and last comment lines end in a space, like Xcode's.
        "// \n"
            + "// \(outputFileName)\n"
            + "// Auto-Generated symbols for localized strings defined in “\(tableName).xcstrings”.\n"
            + "// \n"
            + """

            import Foundation

            #if SWIFT_PACKAGE
            private nonisolated let resourceBundle = Foundation.Bundle.module
            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.atURL(resourceBundle.bundleURL)
            #else

            private class ResourceBundleClass {}
            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.forClass(ResourceBundleClass.self)
            #endif

            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            nonisolated extension LocalizedStringResource {

            """
    }

    private func member(key: String, name: String, comment: String?, arguments: [Argument]) -> String {
        var doc = "    /**\n"
        if let comment {
            doc += "     \(Self.docCommentSafe(comment))\n     \n"
        }
        doc += "     Localized string for key “\(key)” in table “\(tableName).xcstrings”.\n     */\n"

        let identifier = Self.swiftKeywords.contains(name) ? "`\(name)`" : name
        let literal = Self.swiftStringLiteral(key)
        if arguments.isEmpty {
            return doc + """
                static var \(identifier): LocalizedStringResource {
                    LocalizedStringResource(\(literal), table: "\(tableName)", bundle: resourceBundleDescription)
                }
            """
        }
        let parameters = arguments.map { "\($0.label == nil ? "_ \($0.name)" : $0.name): \($0.type)" }.joined(separator: ", ")
        let defaultValue = arguments.map { arg in
            arg.type == "String" ? "\\(\(arg.name))" : "\\(\(arg.name), specifier: \"\(arg.specifier)\")"
        }.joined()
        return doc + """
            static func \(identifier)(\(parameters)) -> LocalizedStringResource {
                LocalizedStringResource(\(literal), defaultValue: "\(defaultValue)", table: "\(tableName)", bundle: resourceBundleDescription)
            }
        """
    }
    // swiftlint:enable line_length

    // MARK: - Arguments

    struct Argument {
        var position: Int
        /// Substitution name for `%#@name@` arguments, which become labeled parameters.
        var label: String?
        var specifier: String
        var type: String
        var name: String { label ?? "arg\(position)" }
    }

    /// Format specifier (length modifier + conversion) to the Swift parameter type Xcode generates.
    static let swiftTypes: [String: String] = [
        "@": "String",
        "d": "Int32", "ld": "Int", "lld": "Int",
        "u": "UInt32", "lu": "UInt", "llu": "UInt",
        "f": "Float", "lf": "Double", "g": "Double",
    ]

    private func arguments(for entry: Entry) -> Result<[Argument], SymbolError> {
        var byPosition: [Int: Argument] = [:]

        func collect(_ value: String, substitutions: [String: Substitution]) -> SymbolError? {
            var next = 1
            for token in FormatString.tokenize(value) {
                switch token {
                case .specifier(let spec, _):
                    let position = spec.position ?? next
                    next = position + 1
                    let printed = "%" + spec.withoutPosition
                    guard let type = Self.swiftTypes[spec.valueType] else {
                        return SymbolError("Unable to create a Swift type from the format specifier “\(printed)”.")
                    }
                    if byPosition[position] == nil {
                        byPosition[position] = Argument(position: position, label: nil, specifier: printed, type: type)
                    }
                case .substitution(let name, let explicit, _):
                    guard let substitution = substitutions[name] else { continue }
                    let position = explicit ?? substitution.argNum
                    next = position + 1
                    let printed = "%" + substitution.formatSpecifier
                    guard let type = Self.swiftTypes[substitution.formatSpecifier] else {
                        return SymbolError("Unable to create a Swift type from the format specifier “\(printed)”.")
                    }
                    byPosition[position] = Argument(position: position, label: name, specifier: printed, type: type)
                case .literal, .percent:
                    continue
                }
            }
            return nil
        }

        func walk(_ node: VariationNode, substitutions: [String: Substitution]) -> SymbolError? {
            switch node {
            case .stringUnit(let unit): return collect(unit.value, substitutions: substitutions)
            case .variations(let variations): return walk(variations, substitutions: substitutions)
            }
        }
        func walk(_ variations: Variations, substitutions: [String: Substitution]) -> SymbolError? {
            switch variations {
            case .plural(let cases), .device(let cases):
                for (_, node) in cases {
                    if let error = walk(node, substitutions: substitutions) { return error }
                }
            }
            return nil
        }

        // The source language decides argument order and types; other languages fill in when it has none.
        let languages = [catalog.sourceLanguage] + entry.localizations.keys.filter { $0 != catalog.sourceLanguage }.sorted()
        for language in languages {
            guard let localization = entry.localizations[language] else { continue }
            let error: SymbolError?
            if let variations = localization.variations {
                error = walk(variations, substitutions: localization.substitutions)
            } else if let unit = localization.stringUnit {
                error = collect(unit.value, substitutions: localization.substitutions)
            } else {
                error = nil
            }
            if let error { return .failure(error) }
        }

        let positions = byPosition.keys.sorted()
        if let last = positions.last, last != positions.count {
            return .failure(SymbolError(
                "Some argument numbers were skipped. "
                    + "Make sure that each argument number is referenced in the translation of at least one language."
            ))
        }
        return .success(positions.map { byPosition[$0]! })
    }

    struct SymbolError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Naming

    /// Symbols (compared case-insensitively) that would clash with members every type has.
    static let reservedNames: Set<String> = ["self", "type", "protocol"]

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
        "Any", "as", "await", "false", "is", "nil", "super", "throws", "true", "try",
    ]

    /// Derives a lower-camel-case identifier from a key: `CHAT_COOKIE_USE` -> `chatCookieUse`,
    /// `PascalCase` -> `pascalCase`, `x2y` -> `x2Y`, `123abc` -> `_123Abc`.
    static func symbolName(for key: String) -> String { // swiftlint:disable:this cyclomatic_complexity
        // Xcode names keys holding `%#@name@` after their positional form (`%1$#@name@`).
        let key = key.contains("%") ? FormatString.makeSubstitutionsPositional(key) : key
        func isWordCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "$" || c.unicodeScalars.contains { $0.properties.isEmoji && !$0.isASCII }
        }
        var words: [String] = []
        var current = ""
        for c in key {
            if isWordCharacter(c) {
                current.append(c)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return "" }

        let leadingUnderscore = key.first == "_"
        var result = ""
        for (index, word) in words.enumerated() {
            // A letter after a digit or `$` starts a new segment: `C2PA` -> `C`, `2PA`.
            var segments: [Substring] = []
            var start = word.startIndex
            var i = word.startIndex
            while i < word.endIndex {
                let next = word.index(after: i)
                if next < word.endIndex, !word[i].isLetter, word[next].isLetter {
                    segments.append(word[start..<next])
                    start = next
                }
                i = next
            }
            segments.append(word[start...])

            for (segmentIndex, segment) in segments.enumerated() {
                // Only a segment's leading run of capitals is folded: `NSFaceID` -> `NsfaceID`, `SNAKE` -> `Snake`.
                let run = segment.prefix(while: \.isUppercase)
                let rest = segment.dropFirst(run.count)
                if index == 0 && segmentIndex == 0 && !leadingUnderscore {
                    result += run.lowercased() + rest
                } else if run.isEmpty {
                    result += segment.prefix(1).uppercased() + segment.dropFirst()
                } else {
                    result += run.prefix(1) + run.dropFirst().lowercased() + rest
                }
            }
        }

        // A letter after a digit or `$` starts a new word.
        var capitalized = ""
        var previous: Character?
        for c in result {
            if let previous, previous.isNumber || previous == "$", c.isLetter {
                capitalized += c.uppercased()
            } else {
                capitalized.append(c)
            }
            previous = c
        }
        if leadingUnderscore || capitalized.first?.isNumber == true {
            capitalized = "_" + capitalized
        }
        return capitalized
    }

    /// Breaks up `//`, `/*` and `*/` so a comment can't end or nest the generated doc comment.
    static func docCommentSafe(_ comment: String) -> String {
        var out = ""
        var previous: Character?
        for c in comment {
            if let previous, (previous == "/" && (c == "/" || c == "*")) || (previous == "*" && c == "/") {
                out.append(" ")
            }
            out.append(c)
            previous = c
        }
        return out
    }

    static func swiftStringLiteral(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
