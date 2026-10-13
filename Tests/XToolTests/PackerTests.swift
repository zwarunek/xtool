import Foundation
import Testing
@testable import PackLib

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

@Test func embeddedFrameworksDropHeadersAndModules() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("xtool-embed-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    let src = root.appendingPathComponent("Example.framework")
    for dir in ["Headers", "PrivateHeaders", "Modules", "Example_Privacy.bundle"] {
        try fileManager.createDirectory(at: src.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try Data("binary".utf8).write(to: src.appendingPathComponent("Example"))
    try Data("plist".utf8).write(to: src.appendingPathComponent("Info.plist"))
    try Data("header".utf8).write(to: src.appendingPathComponent("Headers/Example.h"))
    try Data("module".utf8).write(to: src.appendingPathComponent("Modules/module.modulemap"))
    try Data("privacy".utf8).write(to: src.appendingPathComponent("Example_Privacy.bundle/PrivacyInfo.xcprivacy"))

    let dst = root.appendingPathComponent("App.app/Frameworks/Example.framework")
    try Packer.copyFrameworkForEmbedding(from: src, to: dst)

    let contents = try fileManager.contentsOfDirectory(atPath: dst.path).sorted()
    #expect(contents == ["Example", "Example_Privacy.bundle", "Info.plist"])
    let privacyInfo = dst.appendingPathComponent("Example_Privacy.bundle/PrivacyInfo.xcprivacy")
    #expect(fileManager.fileExists(atPath: privacyInfo.path))
}
