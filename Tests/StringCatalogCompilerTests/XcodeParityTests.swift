import Foundation
import Testing
@testable import StringCatalogCompiler

/// Compiles each fixture catalog and compares the result with what Xcode 26.5's `xcstringstool` produced.
@Suite struct XcodeParityTests {
    static let fixtures: URL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static func options(for fixture: String) -> XCStringsCompiler.Options {
        var options = XCStringsCompiler.Options()
        if fixture.hasSuffix("-force") { options.forceBuildAllStrings = true }
        if fixture.hasSuffix("-languages") { options.languages = ["de", "fr", "en"] }
        if fixture.hasSuffix("-stringsdictOnly") { options.format = .stringsdictOnly }
        return options
    }

    static func files(under directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return result
        }
        let base = directory.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(base.count))] = try? Data(contentsOf: url)
        }
        return result
    }

    @Test(arguments: [
        "Synthetic", "Probe", "Other", "Empty",
        "Synthetic-force", "Probe-force", "Other-force",
        "Synthetic-languages", "Other-stringsdictOnly",
    ])
    func matchesXcodeByteForByte(_ fixture: String) throws {
        let dir = Self.fixtures.appendingPathComponent(fixture)
        let catalog = try Catalog(data: Data(contentsOf: dir.appendingPathComponent("Localizable.xcstrings")))
        let result = XCStringsCompiler(catalog: catalog, tableName: "Localizable", options: Self.options(for: fixture)).compile()
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let expected = Self.files(under: dir.appendingPathComponent("expected"))
        var actual: [String: Data] = [:]
        for output in result.outputs {
            actual[output.relativePath] = try output.data(.text)
        }
        #expect(Set(actual.keys) == Set(expected.keys))
        for (path, data) in expected {
            let ours = actual[path].map { String(decoding: $0, as: UTF8.self) }
            #expect(ours == String(decoding: data, as: UTF8.self), "\(fixture)/\(path)")
        }
    }

    @Test func reportsXcodeDiagnostics() throws {
        let dir = Self.fixtures.appendingPathComponent("Invalid")
        let catalog = try Catalog(data: Data(contentsOf: dir.appendingPathComponent("Localizable.xcstrings")))
        let result = XCStringsCompiler(catalog: catalog, tableName: "Localizable").compile()
        let ours = Set(result.diagnostics.map(\.description))
        // Xcode stops after the first language with errors, so its list is a subset of ours.
        let expected = try String(contentsOf: dir.appendingPathComponent("expected-errors.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(!expected.isEmpty)
        for line in expected {
            #expect(ours.contains(line), "missing: \(line)")
        }
    }

    @Test func binarySerializationRoundTrips() throws {
        let dir = Self.fixtures.appendingPathComponent("Synthetic")
        let catalog = try Catalog(data: Data(contentsOf: dir.appendingPathComponent("Localizable.xcstrings")))
        let result = XCStringsCompiler(catalog: catalog, tableName: "Localizable").compile()
        for output in result.outputs {
            let binary = try output.data(.binary)
            #expect(binary.starts(with: Array("bplist00".utf8)))
            let decoded = try PropertyListSerialization.propertyList(from: binary, format: nil) as? NSDictionary
            let text = try PropertyListSerialization.propertyList(from: output.data(.text), format: nil) as? NSDictionary
            #expect(decoded == text)
        }
    }

    @Test func formatSpecifiers() {
        let args = FormatString.arguments(in: "%@ has %lld of %2$lld %% %.1f")
        #expect(args.map(\.0) == [1, 2, 2, 3])
        #expect(args.map(\.1.valueType) == ["@", "lld", "lld", "f"])
        #expect(FormatString.makePositional("%@ has %lld%%") == "%1$@ has %2$lld%%")
        #expect(FormatString.substitutionReferences(in: "I saw %#@birds@ in %2$#@yards@") == ["birds", "yards"])
        #expect(FormatString.rewriteSubstitutionReferences(in: "%#@a@ / %3$#@b@") { $0 == "a" ? 2 : 9 } == "%2$#@a@ / %3$#@b@")
    }

    @Test func languageCanonicalization() {
        #expect(XCStringsCompiler.canonicalLanguage("en-gb") == "en-GB")
        #expect(XCStringsCompiler.canonicalLanguage("zh-hant") == "zh-Hant")
        #expect(XCStringsCompiler.canonicalLanguage("EN-au") == "en-AU")
        #expect(XCStringsCompiler.canonicalLanguage("es-419") == "es-419")
        #expect(XCStringsCompiler.canonicalLanguage("pt_BR") == "pt_BR")
    }

    @Test func dictionaryKeysSortLikeCoreFoundation() {
        // UTF-16 code unit order: surrogate pairs (emoji) sort before U+FF5A.
        let keys = ["sort ｚ", "sort 😀", "sort a", "sort A", "sort _"]
        #expect(keys.sorted(by: XCStringsCompiler.literalLess) == ["sort A", "sort _", "sort a", "sort 😀", "sort ｚ"])
    }
}

@Suite struct SymbolGeneratorParityTests {
    @Test(arguments: ["Synthetic", "Probe", "Other", "Empty", "Symbols"])
    func matchesXcodeByteForByte(_ fixture: String) throws {
        let dir = XcodeParityTests.fixtures.appendingPathComponent(fixture)
        let catalog = try Catalog(data: Data(contentsOf: dir.appendingPathComponent("Localizable.xcstrings")))
        let (source, diagnostics) = SymbolGenerator(catalog: catalog, tableName: "Localizable").generate()
        let expected = try String(contentsOf: dir.appendingPathComponent("expected-symbols.swift"), encoding: .utf8)
        #expect(source == expected)

        let errorsFile = dir.appendingPathComponent("expected-symbol-errors.txt")
        let expectedErrors = (try? String(contentsOf: errorsFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(diagnostics.map(\.description).sorted() == expectedErrors.sorted())
    }

    @Test func symbolNames() {
        let cases = [
            "CHAT_COOKIE_USE": "chatCookieUse",
            "INFO_PLIST_NSFaceIDUsageDescription": "infoPlistNsfaceIDUsageDescription",
            "SETTINGS_SECURITY_2FA_BACKUP": "settingsSecurity2FaBackup",
            "COMPOSE_VIEW_C2PA_AI": "composeViewC2PaAi",
            "HTTPStatus": "httpstatus",
            "myURLHandler": "myURLHandler",
            "x2y": "x2Y",
            "123leading": "_123Leading",
            "__double": "_Double",
        ]
        for (key, name) in cases {
            #expect(SymbolGenerator.symbolName(for: key) == name, "\(key)")
        }
    }
}
