import Foundation
import XKit
import XToolSupport
import Dependencies
import StringCatalogCompiler

@_documentation(visibility: private)
@main
enum XToolMain {
    static func main() async throws {
        // Multi-call: the Darwin SDK's Xcode tool shims (see SDKBuilder.installXcodeToolShims) run this binary.
        let invokedAs = ProcessInfo.processInfo.environment["XTOOL_MULTICALL"]
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        if invokedAs == "xcstringstool" {
            exit(XCStringsToolCommand.run(Array(CommandLine.arguments.dropFirst())))
        }

        prepareDependencies { _ in
            // TODO: Improve persistence mechanism
            // for Windows, we could use dpapi.h or wincred.h.
            // for Linux, maybe use libsecret?
            // see https://github.com/atom/node-keytar
        }
        try await XTool.run()
    }
}
