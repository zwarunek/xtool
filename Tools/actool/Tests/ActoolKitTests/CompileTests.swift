import Foundation
import XCTest

@testable import ActoolKit

/// Compiles Fixtures/Synth.xcassets and compares the result with what Xcode 26.5's actool produced for the
/// same catalog (Fixtures/Reference, generated on macOS with Scripts/make-references.sh).
final class CompileTests: XCTestCase {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static let catalogURL = fixtures.appendingPathComponent("Synth.xcassets")

    /// System color references are not supported (a warning is emitted instead).
    static let unsupported: Set<String> = ["Colors/c-system"]

    func compile(deploymentTarget: String, appIcon: String?, alternates: [String] = [], includeAll: Bool = false) throws -> CompileResult {
        var options = CompileOptions()
        options.platform = "iphoneos"
        options.minimumDeploymentTarget = deploymentTarget
        options.targetDevices = ["iphone", "ipad"]
        options.appIcon = appIcon
        options.alternateAppIcons = alternates
        options.includeAllAppIcons = includeAll
        let catalog = try AssetCatalog(url: Self.catalogURL)
        return CatalogCompiler(options: options).compile([catalog])
    }

    func reference(_ variant: String, _ file: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("Reference/\(variant)/\(file)"))
    }

    func assertMatchesReference(_ result: CompileResult, variant: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let car = try XCTUnwrap(result.car, file: file, line: line)
        var options = CARComparison.Options()
        options.ignoredFacets = Self.unsupported
        let comparison = try CARComparison.compare(reference: reference(variant, "Assets.car"), candidate: car, options: options)
        XCTAssertTrue(comparison.isMatch, "\(variant):\n\(comparison)", file: file, line: line)
        XCTAssertGreaterThan(comparison.matchedRenditions, 50, file: file, line: line)
    }

    func testIOS26CatalogMatchesActool() throws {
        let result = try compile(deploymentTarget: "26.0", appIcon: "AppIcon", alternates: ["AltIcon"])
        try assertMatchesReference(result, variant: "ios26")
        XCTAssertEqual(result.diagnostics.filter { $0.kind == .error }.map(\.message), [])
    }

    func testIOS17CatalogMatchesActool() throws {
        try assertMatchesReference(try compile(deploymentTarget: "17.0", appIcon: "AltIcon"), variant: "ios17")
    }

    func testIOS15CatalogMatchesActool() throws {
        try assertMatchesReference(try compile(deploymentTarget: "15.0", appIcon: "AppIcon", includeAll: true), variant: "ios15")
    }

    func testPartialInfoPlistMatchesActool() throws {
        for (variant, result) in [
            ("ios26", try compile(deploymentTarget: "26.0", appIcon: "AppIcon", alternates: ["AltIcon"])),
            ("ios17", try compile(deploymentTarget: "17.0", appIcon: "AltIcon")),
            ("ios15", try compile(deploymentTarget: "15.0", appIcon: "AppIcon", includeAll: true)),
        ] {
            let expected = try PropertyListSerialization.propertyList(from: reference(variant, "partial.plist"), format: nil) as? NSDictionary
            let actual = try PropertyListSerialization.propertyList(from: PlistXML.encode(result.partialInfoPlist), format: nil) as? NSDictionary
            XCTAssertEqual(actual, expected, variant)
        }
    }

    func testAppIconFilesMatchActool() throws {
        let result = try compile(deploymentTarget: "26.0", appIcon: "AppIcon", alternates: ["AltIcon"])
        XCTAssertEqual(result.files.map(\.name).sorted(), ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"])
        for file in result.files {
            let bitmap = try Bitmap.decode(file.data)
            XCTAssertEqual(bitmap.width, file.name.contains("60x60") ? 120 : 152)
        }
    }

    func testGeneratedSymbolsMatchActool() throws {
        let catalog = try AssetCatalog(url: Self.catalogURL)
        var options = AssetSymbolOptions()
        options.bundleIdentifier = "com.example.synth"
        options.generateSwiftExtensions = false
        let generator = AssetSymbolGenerator(catalogs: [catalog], options: options)
        XCTAssertEqual(generator.swiftSource(), String(decoding: try reference("ios26", "GeneratedAssetSymbols.swift"), as: UTF8.self))
        XCTAssertEqual(generator.objcHeader(), String(decoding: try reference("ios26", "GeneratedAssetSymbols.h"), as: UTF8.self))
    }

    func testColorsAreExact() throws {
        let car = try CARReader(XCTUnwrap(try compile(deploymentTarget: "26.0", appIcon: nil).car))
        let p3 = try XCTUnwrap(car.renditions(named: "Colors/c-p3").first?.color())
        XCTAssertEqual(p3.space, 3)
        XCTAssertEqual(p3.components, [1, 0, 0, 1])
        let hex = try XCTUnwrap(car.renditions(named: "Colors/c-srgb-hex").first?.color())
        XCTAssertEqual(hex.components, [1, 128.0 / 255, 0, Double(Float(0.5))])
        let appearances = car.renditions(named: "c-appearances").compactMap { $0.key[.appearance] }.sorted()
        XCTAssertEqual(appearances, [0, 0, 1, 2, 3, 4])
    }

    func testRastersRoundTrip() throws {
        let car = try CARReader(XCTUnwrap(try compile(deploymentTarget: "26.0", appIcon: nil).car))
        let opaque = try XCTUnwrap(car.renditions(named: "i-opaque").first?.bitmap())
        XCTAssertEqual(opaque.width, 16)
        // Solid blue, stored as B, G, R, A.
        XCTAssertEqual(Array(opaque.pixels[0..<4]), [200, 0, 0, 255])
        let data = try XCTUnwrap(car.renditions(named: "d-json").first?.rawData())
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"hello\": \"world\", \"n\": 1}\n")
    }
}
