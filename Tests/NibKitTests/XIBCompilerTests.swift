import Foundation
import Testing
@testable import NibKit

// Each fixture xib sits next to the nib Xcode 26.5's ibtool built from it with the arguments SwiftBuild passes
// (--module Fixtures --target-device iphone --target-device ipad --minimum-deployment-target 15.0).

private func fixture(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(path)
    #expect(FileManager.default.fileExists(atPath: url.path), "missing fixture \(path)")
    return url
}

@Test(arguments: ["Cell", "Controller", "Base.lproj/Panel"])
func compiledNibMatchesIBTool(name: String) throws {
    let xib = try Data(contentsOf: fixture("\(name).xib"))
    let reference = try NibArchive.decode([UInt8](Data(contentsOf: fixture("\(name).nib"))))
    let result = try XIBCompiler.compile(
        xib: xib,
        options: XIBCompileOptions(module: "Fixtures", localizable: name.contains(".lproj/"))
    )
    #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    let compiled = try NibArchive.decode(result.nib)
    let difference = NibCanonical.difference(reference: reference, candidate: compiled)
    #expect(difference.isEmpty, "\(difference.joined(separator: "\n"))")
}

@Test func archiveRoundTrip() throws {
    let root = NibObject("NSObject")
    let string = NibObject("NSString")
    string.add("NS.bytes", .data(Array("hello".utf8)))
    let color = NibObject("UIColor", fallbacks: ["NSColor"])
    color.add("UIWhite", .float(0.5))
    root.add("small", .int(5))
    root.add("medium", .int(4096))
    root.add("large", .int(131_072))
    root.add("huge", .int(2_147_517_444))
    root.add("negative", .int(-1))
    root.add("yes", .bool(true))
    root.add("no", .bool(false))
    root.add("double", .double(0.25))
    root.add("nothing", .null)
    root.add("string", .object(string))
    root.add("again", .object(string))
    root.add("color", .object(color))

    let bytes = NibArchive.encode(root: root)
    #expect(Array(bytes.prefix(10)) == Array("NIBArchive".utf8))
    let decoded = try NibArchive.decode(bytes)
    #expect(NibArchive.dump(decoded) == NibArchive.dump(root))
    guard case .object(let first)? = decoded["string"], case .object(let second)? = decoded["again"] else {
        Issue.record("object references did not decode")
        return
    }
    #expect(first === second)
    guard case .object(let decodedColor)? = decoded["color"] else {
        Issue.record("color did not decode")
        return
    }
    #expect(decodedColor.classFallbacks == ["NSColor"])
}

@Test func unsupportedElementsAreReported() throws {
    let xib = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <document type="com.apple.InterfaceBuilder3.CocoaTouch.XIB" version="3.0" toolsVersion="21701" \
    targetRuntime="iOS.CocoaTouch" useAutolayout="YES">
        <objects>
            <placeholder placeholderIdentifier="IBFilesOwner" id="-1"/>
            <view contentMode="scaleToFill" id="aaa-bb-ccc">
                <rect key="frame" x="0.0" y="0.0" width="100" height="100"/>
                <subviews>
                    <mapView contentMode="scaleToFill" id="ddd-ee-fff"/>
                </subviews>
                <freeformSimulatedSizeMetrics key="simulatedDestinationMetrics"/>
            </view>
        </objects>
    </document>
    """.utf8)
    let result = try XIBCompiler.compile(xib: xib)
    #expect(result.diagnostics.contains { $0.message.contains("mapView") })
}

@Test func storyboardsAreRejected() {
    let storyboard = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0"><scenes/></document>
    """.utf8)
    #expect(throws: XIBCompileError.self) { try XIBCompiler.compile(xib: storyboard) }
}
