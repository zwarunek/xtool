#if !os(Windows)
import Foundation
import Testing
@testable import XToolSupport

/// Runs the `ld64.lld` wrapper from the Darwin SDK toolset against stub linkers that record their arguments.
@Suite struct LD64TrampolineTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ld64-trampoline-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("orig"), withIntermediateDirectories: true)
        try write(SDKBuilder.ld64Trampoline, to: "bin/ld64.lld", executable: true)
        // The stub linkers record their arguments, and each -filelist's contents, to record-<tool>.txt.
        for tool in ["orig/ld64.lld", "llvm-lib"] {
            let record = dir.appendingPathComponent("record-\(URL(fileURLWithPath: tool).lastPathComponent).txt").path
            try write("""
            #!/bin/sh
            : > '\(record)'
            prev=
            for a do
                printf 'arg %s\\n' "$a" >> '\(record)'
                if [ "$prev" = "-filelist" ]; then
                    while IFS= read -r l; do printf 'list %s\\n' "$l" >> '\(record)'; done < "$a"
                fi
                prev="$a"
            done
            """, to: "bin/\(tool)", executable: true)
        }
        try write("!<arch>\nmerged module objects\n", to: "Merged.o")
        try write("\u{CF}\u{FA}\u{ED}\u{FE} mach-o", to: "Plain.o")
        try write("!<arch>\nreal static library\n", to: "libStatic.a")
    }

    func write(_ contents: String, to path: String, executable: Bool = false) throws {
        let url = dir.appendingPathComponent(path)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [dir.appendingPathComponent("bin/ld64.lld").path] + arguments
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func record(_ name: String) throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test func forceLoadsRelocatableArchivesInNormalLinks() throws {
        let list = dir.appendingPathComponent("Dyn.LinkFileList")
        try "\(dir.path)/Merged.o\n\(dir.path)/Plain.o\n".write(to: list, atomically: true, encoding: .utf8)

        #expect(try run(["-dylib", "-filelist", list.path, "\(dir.path)/libStatic.a", "-o", "libDyn.dylib"]) == 0)

        let args = try record("record-ld64.lld.txt")
        // The archive standing in for an `ld -r` object leaves the file list and is force-loaded instead.
        #expect(args.contains("list \(dir.path)/Plain.o"))
        #expect(!args.contains("list \(dir.path)/Merged.o"))
        #expect(args.suffix(from: args.firstIndex(of: "arg -force_load")!).dropFirst().first == "arg \(dir.path)/Merged.o")
        // Real static libraries keep their lazy semantics.
        #expect(args.contains("arg \(dir.path)/libStatic.a"))
        #expect(!args.contains("arg \(dir.path)/Plain.o"))
        #expect(args.contains("arg -dylib") && args.contains("arg libDyn.dylib"))
    }

    @Test func reservesHeaderPaddingInNormalLinks() throws {
        #expect(try run(["-execute", "\(dir.path)/Plain.o", "-o", "app"]) == 0)

        let args = try record("record-ld64.lld.txt")
        #expect(args.first == "arg -headerpad_max_install_names")
        #expect(args.contains("arg \(dir.path)/Plain.o") && args.contains("arg app"))
    }

    @Test func relocatableLinksStillProduceArchives() throws {
        let list = dir.appendingPathComponent("Mod.LinkFileList")
        try "\(dir.path)/Plain.o\n".write(to: list, atomically: true, encoding: .utf8)

        #expect(try run(["-r", "-filelist", list.path, "-dependency_info", "deps.dat", "-o", "Mod.o"]) == 0)

        let args = try record("record-llvm-lib.txt")
        #expect(args.prefix(2) == ["arg -static", "arg -filelist"])
        #expect(args.contains("arg Mod.o"))
    }
}
#endif
