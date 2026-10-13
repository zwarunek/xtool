import Foundation
import XCTest

@testable import ActoolKit

final class BOMTests: XCTestCase {
    func testMultiLevelTreeRoundTrip() throws {
        let bom = BOMWriter()
        let entries = (0..<1500).map { i -> (key: Data, value: Data) in
            (Data(String(format: "key-%05d", i).utf8), Data("value \(i)".utf8))
        }
        bom.addTree("TREE", entries: entries)
        var inline = ByteWriter()
        inline.u32le(42)
        bom.addTree("INLINE", entries: [(inline.data, Data([1, 2, 3]))], blockSize: 1024, inlineKeys: true)
        let reader = try BOMReader(bom.serialize())
        let back = try reader.tree("TREE")
        XCTAssertEqual(back.count, 1500)
        XCTAssertEqual(back.map(\.key), entries.map(\.key))
        XCTAssertEqual(back.last?.value, Data("value 1499".utf8))
        XCTAssertEqual(try reader.tree("INLINE").first?.key, inline.data)
    }
}

final class SymbolNameTests: XCTestCase {
    func testSwiftIdentifiers() {
        let cases: [(String, String)] = [
            ("app-icon-black", "appIconBlack"),
            ("i-3h", "i3H"),
            ("v-pdf-2x", "vPdf2X"),
            ("c-gray22", "cGray22"),
            ("Black", "black"),
            ("ABCHeader2026Logo", "abcHeader2026Logo"),
            ("arrow_360_rotate", "arrow360Rotate"),
            ("photo_image", "photo"),
            ("BrandAccentColor", "brandAccent"),
            ("logo_g_color", "logoG"),
            ("X", "X"),
            ("Icon-X-Mars-settings", "iconXMarsSettings"),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(AssetSymbolGenerator.swiftIdentifier(name), expected, name)
        }
    }
}

final class PDFTests: XCTestCase {
    func testRendersPathsFormsAndOpacity() throws {
        let url = CompileTests.catalogURL.appendingPathComponent("v-pdf.imageset/shape.pdf")
        let doc = try PDFDocument(data: Data(contentsOf: url))
        let size = try doc.firstPageSize()
        XCTAssertEqual(size.width, 100.5, accuracy: 0.001)
        let bmp = try doc.renderFirstPage(width: 201, height: 201)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bmp.pixels[((y * bmp.width) + x) * 4..<((y * bmp.width) + x) * 4 + 4]) }
        // Corner of the blue square (0.2, 0.4, 0.8) with the page's y axis flipped.
        XCTAssertEqual(pixel(30, 170), [204, 102, 51, 255])
        // Outside the square stays transparent.
        XCTAssertEqual(pixel(2, 2)[3], 0)
        // The half-transparent green square over blue.
        let mixed = pixel(120, 131)
        XCTAssertGreaterThan(Int(mixed[1]), 100)
    }
}

final class SymbolTemplateTests: XCTestCase {
    func testTemplateProducesGlyphsForEachWeight() throws {
        let url = CompileTests.catalogURL.appendingPathComponent("sym-custom.symbolset/sym.svg")
        let template = try SymbolTemplate(String(contentsOf: url, encoding: .utf8))
        let glyphs = template.glyphs()
        XCTAssertEqual(glyphs.map { "\($0.weight)-\($0.size)" }.sorted(), ["1-1", "4-1", "5-2", "9-1"])
        for g in glyphs {
            XCTAssertTrue(g.svg.contains("viewBox"))
            XCTAssertGreaterThan(g.capHeight, 11)
        }
    }

    func testArcBoundsIncludeTheCurve() throws {
        let b = try XCTUnwrap(SVGPathBounds.bounds("M10 0a5 5 0 1 0 10 0a5 5 0 1 0 -10 0z"))
        XCTAssertEqual(b.minY, -5, accuracy: 0.05)
        XCTAssertEqual(b.maxY, 5, accuracy: 0.05)
        XCTAssertEqual(b.maxX, 20, accuracy: 0.05)
    }
}

/// Compares against Xcode's output for real catalogs when the environment points at them:
/// ACTOOL_REAL_CATALOGS (a directory of .xcassets plus catalogs.txt listing them in order) and
/// ACTOOL_REAL_REFERENCES (NN/out/Assets.car per catalog, from Scripts/make-references.sh).
final class RealCatalogTests: XCTestCase {
    func testRealCatalogsMatchActool() throws {
        let env = ProcessInfo.processInfo.environment
        guard let catalogs = env["ACTOOL_REAL_CATALOGS"], let references = env["ACTOOL_REAL_REFERENCES"] else {
            throw XCTSkip("set ACTOOL_REAL_CATALOGS and ACTOOL_REAL_REFERENCES to compare real catalogs")
        }
        let list = try String(contentsOfFile: catalogs + "/catalogs.txt", encoding: .utf8).split(separator: "\n").map(String.init)
        var failures: [String] = []
        for (i, entry) in list.enumerated() {
            let n = String(format: "%02d", i + 1)
            let refCar = URL(fileURLWithPath: "\(references)/\(n)/out/Assets.car")
            let catalogURL = URL(fileURLWithPath: catalogs).appendingPathComponent(entry)
            let catalog = try AssetCatalog(url: catalogURL)
            var options = CompileOptions()
            options.targetDevices = ["iphone", "ipad"]
            options.appIcon = catalog.assets.first { $0.kind == .appIconSet }?.name
            let result = CatalogCompiler(options: options).compile([catalog])
            guard FileManager.default.fileExists(atPath: refCar.path) else {
                if result.car != nil { failures.append("\(n) \(entry): actool wrote no Assets.car but this tool did") }
                continue
            }
            guard let car = result.car else {
                failures.append("\(n) \(entry): no Assets.car")
                continue
            }
            let comparison = try CARComparison.compare(reference: Data(contentsOf: refCar), candidate: car)
            print("\(n) \(entry): \(comparison.matchedRenditions) renditions matched\(comparison.isMatch ? "" : ", differences:\n\(comparison)")")
            if !comparison.isMatch { failures.append("\(n) \(entry)") }
        }
        XCTAssertEqual(failures, [])
    }
}

final class IconComposerTests: XCTestCase {
    func testFlattensFillAndLayers() throws {
        let icon = try IconComposerIcon(url: CompileTests.fixtures.appendingPathComponent("Icon.icon"))
        XCTAssertEqual(icon.name, "Icon")
        let flat = try icon.flatten(size: 256)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(flat.pixels[(y * flat.width + x) * 4..<(y * flat.width + x) * 4 + 4]) }
        XCTAssertEqual(pixel(5, 5), [153, 102, 51, 255])
        XCTAssertEqual(pixel(128, 128), [255, 255, 255, 255])
    }

    func testIconComposerIconBecomesTheAppIcon() throws {
        var options = CompileOptions()
        options.targetDevices = ["iphone", "ipad"]
        options.appIcon = "Icon"
        let icon = try IconComposerIcon(url: CompileTests.fixtures.appendingPathComponent("Icon.icon"))
        let result = CatalogCompiler(options: options).compile([], icons: [icon])
        let car = try CARReader(XCTUnwrap(result.car))
        XCTAssertEqual(car.facets["Icon"]?[.part], CARPart.appIcon)
        XCTAssertEqual(result.files.map(\.name).sorted(), ["Icon60x60@2x.png", "Icon76x76@2x~ipad.png"])
        XCTAssertNotNil(result.partialInfoPlist["CFBundleIcons~ipad"])
    }
}
