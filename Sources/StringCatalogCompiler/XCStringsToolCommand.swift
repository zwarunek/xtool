import Foundation

/// Command-line front end compatible with the subset of Xcode's `xcstringstool` that SwiftBuild invokes:
///
///     xcstringstool compile [--dry-run] [-l <lang>]... [--force-build-all-strings]
///         [-f stringsAndStringsdict|stringsdictOnly] [--serialization-format text|binary]
///         --output-directory <dir> <input.xcstrings>
public enum XCStringsToolCommand {
    public static func run(_ arguments: [String]) -> Int32 {
        var stderr = StandardError()
        guard let subcommand = arguments.first else {
            print(usage, to: &stderr)
            return 64
        }
        switch subcommand {
        case "compile":
            return compile(Array(arguments.dropFirst()), stderr: &stderr)
        case "generate-symbols":
            return generateSymbols(Array(arguments.dropFirst()), stderr: &stderr)
        case "--version", "version":
            print("xcstringstool (xtool) 1.0")
            return 0
        case "-h", "--help", "help":
            print(usage)
            return 0
        default:
            print("error: unsupported subcommand '\(subcommand)'. Only 'compile' and 'generate-symbols' are implemented.", to: &stderr)
            return 64
        }
    }

    static let usage = """
    OVERVIEW: Work with .xcstrings files (xtool reimplementation)

    USAGE: xcstringstool compile <input-file> --output-directory <output-directory> [--format <format>] \
    [--language <language> ...] [--serialization-format <serialization-format>] [--dry-run] [--force-build-all-strings]
           xcstringstool generate-symbols --language swift --output-directory <output-directory> <input-file>
    """

    // swiftlint:disable:next cyclomatic_complexity
    private static func compile(_ arguments: [String], stderr: inout StandardError) -> Int32 {
        var options = XCStringsCompiler.Options()
        var input: String?
        var outputDirectory: String?
        var dryRun = false

        var iterator = arguments.makeIterator()
        func value(for flag: String) -> String? {
            guard let value = iterator.next() else {
                print("error: missing value for '\(flag)'", to: &stderr)
                return nil
            }
            return value
        }
        while let argument = iterator.next() {
            switch argument {
            case "--dry-run":
                dryRun = true
            case "--force-build-all-strings":
                options.forceBuildAllStrings = true
            case "-o", "--output-directory":
                guard let v = value(for: argument) else { return 64 }
                outputDirectory = v
            case "-l", "--language":
                guard let v = value(for: argument) else { return 64 }
                options.languages.append(v)
            case "-f", "--format":
                guard let v = value(for: argument) else { return 64 }
                guard let format = XCStringsCompiler.Format(rawValue: v) else {
                    print("error: The value '\(v)' is invalid for '--format <format>'", to: &stderr)
                    return 64
                }
                options.format = format
            case "--serialization-format":
                guard let v = value(for: argument) else { return 64 }
                guard let serialization = XCStringsCompiler.Serialization(rawValue: v) else {
                    print("error: The value '\(v)' is invalid for '--serialization-format <serialization-format>'", to: &stderr)
                    return 64
                }
                options.serialization = serialization
            default:
                if argument.hasPrefix("-") {
                    print("error: Unknown option '\(argument)'", to: &stderr)
                    return 64
                }
                if input != nil {
                    print("error: Unexpected argument '\(argument)'", to: &stderr)
                    return 64
                }
                input = argument
            }
        }
        guard let input else {
            print("error: Missing expected argument '<input-file>'", to: &stderr)
            return 64
        }
        guard let outputDirectory else {
            print("error: Missing expected argument '--output-directory <output-directory>'", to: &stderr)
            return 64
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let inputURL = URL(fileURLWithPath: input, relativeTo: cwd).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true, relativeTo: cwd).standardizedFileURL

        let catalog: Catalog
        do {
            catalog = try Catalog(data: Data(contentsOf: inputURL))
        } catch {
            print("\(inputURL.path): error: \(error)", to: &stderr)
            return 1
        }

        let tableName = inputURL.deletingPathExtension().lastPathComponent
        let result = XCStringsCompiler(catalog: catalog, tableName: tableName, options: options).compile()
        // Like Xcode, --dry-run only reports the files a compile would produce; it doesn't validate.
        if !result.diagnostics.isEmpty && !dryRun {
            for diagnostic in result.diagnostics {
                print("\(inputURL.path): \(diagnostic)", to: &stderr)
            }
            return 1
        }

        if dryRun {
            for output in result.outputs {
                print(outputURL.appendingPathComponent(output.relativePath).path)
            }
            return 0
        }

        do {
            for output in result.outputs {
                let url = outputURL.appendingPathComponent(output.relativePath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try output.data(options.serialization).write(to: url, options: .atomic)
            }
        } catch {
            print("\(inputURL.path): error: \(error)", to: &stderr)
            return 1
        }
        return 0
    }
}

extension XCStringsToolCommand {
    private static func generateSymbols(_ arguments: [String], stderr: inout StandardError) -> Int32 {
        var input: String?
        var outputDirectory: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--language", "-l":
                guard let language = iterator.next() else {
                    print("error: missing value for '\(argument)'", to: &stderr)
                    return 64
                }
                guard language == "swift" else {
                    print("error: The value '\(language)' is invalid for '--language <language>'", to: &stderr)
                    return 64
                }
            case "--output-directory", "-o":
                guard let value = iterator.next() else {
                    print("error: missing value for '\(argument)'", to: &stderr)
                    return 64
                }
                outputDirectory = value
            default:
                if argument.hasPrefix("-") || input != nil {
                    print("error: Unexpected argument '\(argument)'", to: &stderr)
                    return 64
                }
                input = argument
            }
        }
        guard let input, let outputDirectory else {
            print("error: Missing expected argument '--output-directory <output-directory> <input-file>'", to: &stderr)
            return 64
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let inputURL = URL(fileURLWithPath: input, relativeTo: cwd).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true, relativeTo: cwd).standardizedFileURL
        do {
            let catalog = try Catalog(data: Data(contentsOf: inputURL))
            let generator = SymbolGenerator(catalog: catalog, tableName: inputURL.deletingPathExtension().lastPathComponent)
            let (source, diagnostics) = generator.generate()
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: outputURL.appendingPathComponent(generator.outputFileName), options: .atomic)
            for diagnostic in diagnostics {
                print("\(inputURL.path): \(diagnostic)", to: &stderr)
            }
            return diagnostics.isEmpty ? 0 : 1
        } catch {
            print("\(inputURL.path): error: \(error)", to: &stderr)
            return 1
        }
    }
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
