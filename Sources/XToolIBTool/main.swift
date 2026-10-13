import Foundation
import NibKit

// A Linux stand-in for Xcode's ibtool covering what SwiftBuild's CompileXIB task runs:
//   ibtool [--errors] [--warnings] [--notices] [--module M] [--output-partial-info-plist P]
//          [--auto-activate-custom-fonts] [--target-device D]... [--minimum-deployment-target V]
//          [--output-format human-readable-text|xml1] --compile OUT.nib IN.xib
//   ibtool --version --output-format xml1
// plus `ibtool --dump FILE.nib` to print a nib's object graph and `ibtool --compare REFERENCE.nib CANDIDATE.nib`
// to check a nib against one from Xcode (exit status 1 when they differ).

let toolVersion = (bundle: "24765", short: "26.5")

struct Options {
    var compileOutput: String?
    var inputs: [String] = []
    var module: String?
    var partialInfoPlist: String?
    var outputFormat = "human-readable-text"
    var version = false
    var dump: String?
    var compare = false
    var printWarnings = true
    var printNotices = true
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var i = 0
    // Flags that take a value we accept and ignore.
    let ignoredWithValue: Set<String> = [
        "--target-device", "--minimum-deployment-target", "--platform", "--plugin", "--plugin-dir",
        "--companion-strings-file", "--sdk", "--flatten", "--cocoatouch-compiler-mode",
        "--compilation-mode-for-ios", "--export-dependency-info", "--output-dependencies", "--localization-locale",
        "--compilation-directory",
    ]
    while i < arguments.count {
        let argument = arguments[i]
        func value() -> String? {
            i += 1
            return i < arguments.count ? arguments[i] : nil
        }
        switch argument {
        case "--compile": options.compileOutput = value()
        case "--module": options.module = value()
        case "--output-partial-info-plist": options.partialInfoPlist = value()
        case "--output-format": options.outputFormat = value() ?? options.outputFormat
        case "--version": options.version = true
        case "--dump": options.dump = value()
        case "--compare": options.compare = true
        case "--errors", "--auto-activate-custom-fonts", "--use-nibkeyedarchiver-for-macos": break
        case "--warnings": options.printWarnings = true
        case "--notices": options.printNotices = true
        default:
            if ignoredWithValue.contains(argument) {
                _ = value()
            } else if argument.hasPrefix("--") {
                FileHandle.standardError.write(Data("ibtool: note: ignoring unsupported option \(argument)\n".utf8))
            } else {
                options.inputs.append(argument)
            }
        }
        i += 1
    }
    return options
}

func writePlist(_ object: Any, to path: String) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let options = parse(Array(CommandLine.arguments.dropFirst()))

// SwiftBuild reads the version from the key named after the executable it ran (com.apple.<name>.version).
let toolName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent

if options.version {
    let info: [String: Any] = ["com.apple.\(toolName).version": ["bundle-version": toolVersion.bundle,
                                                            "short-bundle-version": toolVersion.short]]
    if options.outputFormat == "xml1" {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        FileHandle.standardOutput.write(data)
    } else {
        emit("/* com.apple.\(toolName).version */\nbundle-version: \(toolVersion.bundle)\nshort-bundle-version: \(toolVersion.short)")
    }
    exit(0)
}

if let dumpPath = options.dump {
    do {
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: dumpPath)))
        print(NibArchive.dump(try NibArchive.decode(bytes)), terminator: "")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(dumpPath): error: \(error)\n".utf8))
        exit(1)
    }
}

if options.compare {
    guard options.inputs.count == 2 else {
        FileHandle.standardError.write(Data("usage: ibtool --compare REFERENCE.nib CANDIDATE.nib\n".utf8))
        exit(64)
    }
    do {
        let nibs = try options.inputs.map { try NibArchive.decode([UInt8](Data(contentsOf: URL(fileURLWithPath: $0)))) }
        let difference = NibCanonical.difference(reference: nibs[0], candidate: nibs[1])
        for line in difference { emit(line) }
        emit("\(difference.count) differing lines")
        exit(difference.isEmpty ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(2)
    }
}

guard let output = options.compileOutput, let input = options.inputs.first else {
    FileHandle.standardError.write(Data("usage: ibtool --compile OUTPUT.nib INPUT.xib\n".utf8))
    exit(64)
}

do {
    guard input.hasSuffix(".xib") else {
        emit("\(input): error: only .xib files are supported by this ibtool (storyboards are not)")
        exit(1)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    let result = try XIBCompiler.compile(xib: data, options: XIBCompileOptions(module: options.module, localizable: input.contains(".lproj/")))
    for diagnostic in result.diagnostics {
        switch diagnostic.severity {
        case .warning where !options.printWarnings: continue
        case .note where !options.printNotices: continue
        default: break
        }
        emit("\(input):\(diagnostic.line.map(String.init) ?? ""): \(diagnostic.severity.rawValue): \(diagnostic.message)")
    }
    let outputURL = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A flattened nib for one device family is a single file; SwiftBuild's ~iphone/~ipad outputs are optional.
    if (try? outputURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        try FileManager.default.removeItem(at: outputURL)
    }
    try Data(result.nib).write(to: outputURL)
    if let plist = options.partialInfoPlist {
        try writePlist(result.partialInfoPlist, to: plist)
    }
} catch {
    emit("\(input):: error: \(error)")
    exit(1)
}
