import ActoolKit
import Foundation

// A Linux replacement for Xcode's actool, with the command-line surface Swift Build uses.

struct Arguments {
    var inputs: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }
}

let flagOptions: Set<String> = [
    "--notices", "--warnings", "--errors", "--version", "--compress-pngs", "--include-all-app-icons",
    "--skip-app-store-deployment", "--include-sticker-content", "--print-asset-tag-combinations", "--print-contents",
    "--enable-on-demand-resources-flag", "--help",
]

let valueOptions: Set<String> = [
    "--compile", "--output-format", "--export-dependency-info", "--output-partial-info-plist", "--platform",
    "--minimum-deployment-target", "--target-device", "--app-icon", "--alternate-app-icon", "--accent-color",
    "--widget-background-color", "--launch-image", "--development-region", "--include-language",
    "--enable-on-demand-resources", "--asset-pack-output-specifications", "--sticker-pack-strings-file",
    "--standalone-icon-behavior", "--stickers-icon-role", "--enable-incremental-distill", "--target-name",
    "--optimization", "--filter-for-thinning-device-configuration", "--filter-for-device-model",
    "--filter-for-device-os-version", "--ui-framework-family", "--sticker-pack-identifier-prefix",
    "--include-partial-info-plist-localizations", "--lightweight-asset-runtime-mode", "--bundle-identifier",
    "--generate-swift-asset-symbols", "--generate-objc-asset-symbols", "--generate-asset-symbol-index",
    "--generate-swift-asset-symbol-extensions", "--generate-asset-symbol-warnings", "--generate-asset-symbol-errors",
    "--generate-asset-symbol-framework-support", "--generate-asset-symbol-backwards-deployment-support",
    "--product-type", "--leaf-asset-catalog", "--dump-car", "--compression", "--app-icon-launch-name",
    "--flattened-app-icon-path", "--source-dir-override",
]

func parse(_ argv: [String]) -> Arguments {
    var args = Arguments()
    var i = 0
    while i < argv.count {
        var a = argv[i]
        var inlineValue: String?
        if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
            inlineValue = String(a[a.index(after: eq)...])
            a = String(a[..<eq])
        }
        if flagOptions.contains(a) {
            args.flags.insert(a)
        } else if valueOptions.contains(a) {
            if let v = inlineValue {
                args.values[a, default: []].append(v)
            } else if i + 1 < argv.count {
                args.values[a, default: []].append(argv[i + 1])
                i += 1
            }
        } else if a.hasPrefix("--") {
            // Unknown option: take a following non-option word as its value.
            if let v = inlineValue {
                args.values[a, default: []].append(v)
            } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("--"), !argv[i + 1].hasSuffix(".xcassets"), !argv[i + 1].hasSuffix(".icon") {
                args.values[a, default: []].append(argv[i + 1])
                i += 1
            } else {
                args.flags.insert(a)
            }
        } else {
            args.inputs.append(a)
        }
        i += 1
    }
    return args
}

enum OutputFormat: String {
    case humanReadable = "human-readable-text"
    case xml1, binary1
}

func emit(_ result: [String: Any], format: OutputFormat) {
    switch format {
    case .humanReadable:
        var text = ""
        for key in result.keys.sorted() {
            text += "/* \(key) */\n"
            if let items = result[key] as? [String] {
                for item in items { text += item + "\n" }
            } else if let items = result[key] as? [[String: Any]] {
                for item in items {
                    let catalog = item["catalog"] as? String
                    let affected = (item["affected-items"] as? [String])?.first
                    let kind = key.hasSuffix("errors") ? "error" : key.hasSuffix("warnings") ? "warning" : "note"
                    var prefix = ""
                    if let catalog { prefix = affected.map { "\(catalog):\($0): " } ?? "\(catalog): " }
                    text += "\(prefix)\(kind): \(item["message"] as? String ?? item["description"] as? String ?? "")\n"
                }
            } else if let dict = result[key] as? [String: Any] {
                for k in dict.keys.sorted() {
                    if let v = dict[k] as? [String] {
                        for item in v { text += item + "\n" }
                    } else {
                        text += "\(k): \(dict[k] ?? "")\n"
                    }
                }
            }
        }
        FileHandle.standardOutput.write(Data(text.utf8))
    case .xml1, .binary1:
        FileHandle.standardOutput.write(PlistXML.encode(result))
    }
}

func writeDependencyInfo(_ path: String, inputs: [String], outputs: [String]) throws {
    var data = Data([0x00])
    data.append(Data("actool-\(ActoolVersion.bundleVersion)".utf8))
    data.append(0)
    for i in inputs {
        data.append(0x10)
        data.append(Data(i.utf8))
        data.append(0)
    }
    for o in outputs {
        data.append(0x40)
        data.append(Data(o.utf8))
        data.append(0)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

func absolute(_ path: String) -> String {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path).standardizedFileURL.path
}

func run() -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    if let log = ProcessInfo.processInfo.environment["XTOOL_ACTOOL_LOG"], let handle = FileHandle(forWritingAtPath: log) ?? (FileManager.default.createFile(atPath: log, contents: nil) ? FileHandle(forWritingAtPath: log) : nil) {
        handle.seekToEndOfFile()
        handle.write(Data((["actool"] + argv).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ").utf8 + [0x0A]))
        handle.closeFile()
    }
    if argv.first == "--compare-car", argv.count >= 3 {
        do {
            var options = CARComparison.Options()
            options.ignorePixelFormat = argv.contains("--ignore-pixel-format")
            let result = try CARComparison.compare(reference: Data(contentsOf: URL(fileURLWithPath: argv[1])), candidate: Data(contentsOf: URL(fileURLWithPath: argv[2])), options: options)
            print(result)
            return result.isMatch ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("actool: \(error)\n".utf8))
            return 2
        }
    }
    let args = parse(argv)
    let format = OutputFormat(rawValue: args.value("--output-format") ?? "human-readable-text") ?? .humanReadable

    if args.has("--version") {
        emit(["com.apple.actool.version": ["bundle-version": ActoolVersion.bundleVersion, "short-bundle-version": ActoolVersion.shortVersion]], format: format)
        return 0
    }
    if let car = args.value("--dump-car") {
        do {
            let text = try CARDump.describe(Data(contentsOf: URL(fileURLWithPath: car)))
            print(text)
            return 0
        } catch {
            FileHandle.standardError.write(Data("actool: \(error)\n".utf8))
            return 1
        }
    }
    if args.has("--print-asset-tag-combinations") {
        emit(["com.apple.actool.asset-tag-combinations": [[String]]()], format: format)
        return 0
    }

    var errors: [[String: Any]] = []
    var warnings: [[String: Any]] = []
    var notices: [[String: Any]] = []
    var catalogs: [AssetCatalog] = []
    var icons: [IconComposerIcon] = []
    for input in args.inputs {
        let path = absolute(input)
        if path.hasSuffix(".icon") {
            do {
                icons.append(try IconComposerIcon(url: URL(fileURLWithPath: path)))
            } catch {
                errors.append(["description": "\(path): \(error)", "message": "\(error)", "catalog": path])
            }
            continue
        }
        guard path.hasSuffix(".xcassets") || path.hasSuffix(".xcstickers") else {
            warnings.append(["description": "\(path): ignoring input that is not an asset catalog", "message": "ignoring input that is not an asset catalog", "catalog": path])
            continue
        }
        do {
            catalogs.append(try AssetCatalog(url: URL(fileURLWithPath: path)))
        } catch {
            errors.append(["description": "\(error)", "message": "\(error)", "catalog": path])
        }
    }

    var output: [String: Any] = [:]
    var outputFiles: [String] = []

    let swiftSymbols = args.value("--generate-swift-asset-symbols")
    let objcSymbols = args.value("--generate-objc-asset-symbols")
    let symbolIndex = args.value("--generate-asset-symbol-index")
    if swiftSymbols != nil || objcSymbols != nil || symbolIndex != nil {
        // Symbol generation is its own invocation: actool writes only the symbol files.
        var symbolOptions = AssetSymbolOptions()
        symbolOptions.bundleIdentifier = args.value("--bundle-identifier") ?? ""
        symbolOptions.generateSwiftExtensions = (args.value("--generate-swift-asset-symbol-extensions") ?? "YES").uppercased() != "NO"
        let frameworks = args.all("--generate-asset-symbol-framework-support")
        if !frameworks.isEmpty { symbolOptions.frameworks = frameworks }
        symbolOptions.backwardsDeployment = args.value("--generate-asset-symbol-backwards-deployment-support")
        symbolOptions.platform = args.value("--platform") ?? "iphoneos"
        symbolOptions.minimumDeploymentTarget = args.value("--minimum-deployment-target") ?? ""
        let generator = AssetSymbolGenerator(catalogs: catalogs, options: symbolOptions)
        do {
            if let p = swiftSymbols {
                try ensureParent(p)
                try Data(generator.swiftSource().utf8).write(to: URL(fileURLWithPath: p))
                outputFiles.append(absolute(p))
            }
            if let p = objcSymbols {
                try ensureParent(p)
                try Data(generator.objcHeader().utf8).write(to: URL(fileURLWithPath: p))
                outputFiles.append(absolute(p))
            }
            if let p = symbolIndex {
                try ensureParent(p)
                try generator.indexPlist().write(to: URL(fileURLWithPath: p))
                outputFiles.append(absolute(p))
            }
        } catch {
            errors.append(["description": "\(error)", "message": "\(error)"])
        }
        output["com.apple.actool.compilation-results"] = ["output-files": outputFiles.sorted()]
        if !errors.isEmpty { output["com.apple.actool.errors"] = errors }
        emit(output, format: format)
        return errors.isEmpty ? 0 : 1
    }

    guard let compileDir = args.value("--compile") else {
        if !catalogs.isEmpty, args.has("--print-contents") {
            for c in catalogs { for a in c.assets { print("\(a.name) \(a.kind.rawValue)") } }
            return 0
        }
        FileHandle.standardError.write(Data("usage: actool --compile <dir> [options] <catalog.xcassets>...\n".utf8))
        return 64
    }

    var options = CompileOptions()
    options.platform = args.value("--platform") ?? "iphoneos"
    options.minimumDeploymentTarget = args.value("--minimum-deployment-target") ?? options.minimumDeploymentTarget
    options.targetDevices = args.all("--target-device")
    options.appIcon = args.value("--app-icon")
    options.alternateAppIcons = args.all("--alternate-app-icon")
    options.includeAllAppIcons = args.has("--include-all-app-icons")
    options.accentColor = args.value("--accent-color")
    options.widgetBackgroundColor = args.value("--widget-background-color")
    options.launchImage = args.value("--launch-image")
    options.includeLanguages = args.all("--include-language")
    if let c = args.value("--compression").flatMap(CSIPayloadCompression.init(rawValue:)) {
        options.compression = c
    } else if let env = ProcessInfo.processInfo.environment["XTOOL_ACTOOL_COMPRESSION"].flatMap(CSIPayloadCompression.init(rawValue:)) {
        options.compression = env
    }

    let compiler = CatalogCompiler(options: options)
    let result = compiler.compile(catalogs, icons: icons)

    let outDir = URL(fileURLWithPath: absolute(compileDir))
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let car = result.car {
            let url = outDir.appendingPathComponent("Assets.car")
            try car.write(to: url)
            outputFiles.append(url.path)
        }
        for file in result.files {
            let url = outDir.appendingPathComponent(file.name)
            try file.data.write(to: url)
            outputFiles.append(url.path)
        }
        if let plistPath = args.value("--output-partial-info-plist") {
            try ensureParent(plistPath)
            try PlistXML.encode(result.partialInfoPlist).write(to: URL(fileURLWithPath: plistPath))
            outputFiles.append(absolute(plistPath))
        }
    } catch {
        errors.append(["description": "\(error)", "message": "\(error)"])
    }

    for d in result.diagnostics {
        let catalog = catalogs.first?.url.path ?? ""
        var entry: [String: Any] = ["description": d.message, "message": d.message, "catalog": catalog]
        if let item = d.item { entry["affected-items"] = [item] }
        switch d.kind {
        case .error: errors.append(entry)
        case .warning: warnings.append(entry)
        case .notice: notices.append(entry)
        }
    }

    if let depPath = args.value("--export-dependency-info") {
        do {
            try ensureParent(depPath)
            try writeDependencyInfo(depPath, inputs: result.inputPaths, outputs: outputFiles)
        } catch {
            errors.append(["description": "\(error)", "message": "\(error)"])
        }
    }

    output["com.apple.actool.compilation-results"] = ["output-files": outputFiles.sorted()]
    if !errors.isEmpty { output["com.apple.actool.errors"] = errors }
    if !warnings.isEmpty, args.has("--warnings") || format != .humanReadable { output["com.apple.actool.document.warnings"] = warnings }
    if !notices.isEmpty, args.has("--notices") { output["com.apple.actool.document.notices"] = notices }
    emit(output, format: format)
    return errors.isEmpty ? 0 : 1
}

func ensureParent(_ path: String) throws {
    let dir = URL(fileURLWithPath: absolute(path)).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

exit(run())
