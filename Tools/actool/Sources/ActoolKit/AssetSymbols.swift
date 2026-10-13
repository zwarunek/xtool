import Foundation

public struct AssetSymbolOptions: Sendable {
    public var bundleIdentifier = ""
    public var generateSwiftExtensions = true
    public var frameworks = ["SwiftUI", "UIKit", "AppKit"]
    public var backwardsDeployment: String?
    public var platform = "iphoneos"
    public var minimumDeploymentTarget = ""

    public init() {}
}

/// Generates GeneratedAssetSymbols.swift / .h / -Index.plist the way actool does.
public struct AssetSymbolGenerator {
    struct Symbol {
        var name: String  // full asset name, e.g. "Colors/c-p3"
        var path: [String]  // namespace components
        var leaf: String
        var swift: String
        var catalog: URL
        var relativePath: String
    }

    let colors: [Symbol]
    let images: [Symbol]
    let symbolImages: [Symbol]
    let options: AssetSymbolOptions

    public init(catalogs: [AssetCatalog], options: AssetSymbolOptions) {
        self.options = options
        var colors: [Symbol] = [], images: [Symbol] = [], symbols: [Symbol] = []
        for catalog in catalogs {
            for asset in catalog.assets {
                let leaf = asset.name.split(separator: "/").last.map(String.init) ?? asset.name
                let rel = "./" + asset.directory.path.dropFirst(catalog.url.path.count + 1)
                let s = Symbol(name: asset.name, path: asset.namespace, leaf: leaf, swift: Self.swiftIdentifier(leaf), catalog: catalog.url, relativePath: String(rel))
                // Sets without any content get no symbol, as with actool.
                switch asset.kind {
                case .colorSet where (asset.contents["colors"]?.array ?? []).contains(where: { $0["color"] != nil }):
                    colors.append(s)
                case .imageSet where (asset.contents["images"]?.array ?? []).contains(where: { $0["filename"] != nil }):
                    images.append(s)
                case .symbolSet: symbols.append(s)
                default: break
                }
            }
        }
        self.colors = colors
        self.images = images
        self.symbolImages = symbols
    }

    // MARK: Identifiers

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal",
        "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
        "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
        "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as", "Any", "false", "is", "nil", "self", "Self",
        "super", "throws", "true", "try", "await", "async",
    ]

    /// Converts an asset name to lower camel case: words split at non-alphanumerics, leading capitals lowered.
    public static func swiftIdentifier(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in name {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return "_" }
        // A lone all-capitals word ("X") keeps its case.
        var out = words.count == 1 && words[0].allSatisfy({ $0.isUppercase || $0.isNumber }) && words[0].count == 1 ? words[0] : lowerLeading(words[0])
        for w in words.dropFirst() {
            out += upperFirstLetter(w)
        }
        // A trailing "Image" or "Color" word is dropped ("photo_image" -> photo, "AccentColor" -> accent).
        for suffix in ["Image", "Color"] where out.hasSuffix(suffix) && out.count > suffix.count {
            out.removeLast(suffix.count)
            break
        }
        if let first = out.first, first.isNumber { out = "_" + out }
        if swiftKeywords.contains(out) { out = "`\(out)`" }
        return out
    }

    static func lowerLeading(_ word: String) -> String {
        let chars = Array(word)
        var i = 0
        while i < chars.count, chars[i].isUppercase { i += 1 }
        if i == 0 { return word }
        if i == chars.count { return word.lowercased() }
        // Keep the last capital of an acronym when a lowercase letter follows ("MLBPost" -> "mlbPost").
        let cut = i > 1 && chars[i].isLowercase ? i - 1 : i
        return String(chars[0..<cut]).lowercased() + String(chars[cut...])
    }

    static func upperFirstLetter(_ word: String) -> String {
        var chars = Array(word)
        if let idx = chars.firstIndex(where: { $0.isLetter }) {
            chars[idx] = Character(chars[idx].uppercased())
        }
        return String(chars)
    }

    static func objcIdentifier(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in name {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { upperFirstLetter($0) }.joined()
    }

    // MARK: Swift

    let header = """
    import Foundation

    """

    func imports() -> String {
        var s = "import Foundation\n"
        if options.generateSwiftExtensions || backDeploys {
            if options.frameworks.contains("AppKit") { s += "#if canImport(AppKit)\nimport AppKit\n#endif\n" }
            if options.frameworks.contains("UIKit") { s += "#if canImport(UIKit)\nimport UIKit\n#endif\n" }
            if options.frameworks.contains("SwiftUI") { s += "#if canImport(SwiftUI)\nimport SwiftUI\n#endif\n" }
        }
        s += "#if canImport(DeveloperToolsSupport)\nimport DeveloperToolsSupport\n#endif\n\n"
        s += "#if SWIFT_PACKAGE\nprivate let resourceBundle = Foundation.Bundle.module\n#else\nprivate class ResourceBundleClass {}\nprivate let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)\n#endif\n\n"
        return s
    }

    /// A namespace tree for emitting nested enums.
    final class Node {
        var name: String
        var children: [String: Node] = [:]
        var symbols: [Symbol] = []
        init(_ name: String) { self.name = name }
    }

    func tree(_ symbols: [Symbol]) -> Node {
        let root = Node("")
        for s in symbols {
            var node = root
            for component in s.path {
                if node.children[component] == nil { node.children[component] = Node(component) }
                node = node.children[component]!
            }
            node.symbols.append(s)
        }
        return root
    }

    /// Children and symbols of a node in actool's order (byte order of the name, namespaces and assets interleaved).
    func ordered(_ node: Node) -> [(String, Node?, Symbol?)] {
        var items: [(String, Node?, Symbol?)] = node.children.values.map { ($0.name, $0, nil) }
        items += node.symbols.map { ($0.leaf, nil, $0) }
        return items.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
    }

    func emitResources(_ node: Node, kind: String, typeName: String, indent: String, out: inout String) {
        for (_, child, symbol) in ordered(node) {
            if let child {
                out += "\(indent)/// The \"\(child.name)\" asset catalog resource namespace.\n"
                out += "\(indent)enum \(Self.namespaceIdentifier(child.name)) {\n\n"
                emitResources(child, kind: kind, typeName: typeName, indent: indent + "    ", out: &out)
                out += "\(indent)}\n\n"
            } else if let s = symbol {
                out += "\(indent)/// The \"\(s.name)\" asset catalog \(kind) resource.\n"
                out += "\(indent)static let \(s.swift) = \(typePrefix)\(typeName)(name: \"\(s.name)\", bundle: resourceBundle)\n\n"
            }
        }
    }

    static func namespaceIdentifier(_ name: String) -> String {
        let id = swiftIdentifier(name)
        return upperFirstLetter(id.hasPrefix("`") ? String(id.dropFirst().dropLast()) : id)
    }

    /// actool writes its own `ColorResource`/`ImageResource` (and initializers taking them) when the deployment
    /// target predates DeveloperToolsSupport's (iOS/tvOS 17, macOS 14, watchOS 10); the symbols then use those.
    var backDeploys: Bool {
        switch options.backwardsDeployment?.uppercased() {
        case "YES": return true
        case "NO": return false
        default: break
        }
        let major = Int(options.minimumDeploymentTarget.split(separator: ".").first ?? "") ?? 0
        guard major > 0 else { return false }
        let platform = options.platform.lowercased()
        if platform.hasPrefix("macosx") { return major < 14 }
        if platform.hasPrefix("watch") { return major < 10 }
        if platform.hasPrefix("xr") { return false }
        return major < 17  // iphoneos, iphonesimulator, appletvos, appletvsimulator
    }

    var typePrefix: String { backDeploys ? "" : "DeveloperToolsSupport." }

    /// Availability attributes, keyed by what they annotate, for the two kinds of output.
    func availability(_ key: String) -> String {
        let modern: [String: String] = [
            "colors": "iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0", "images": "iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0",
            "NSColor": "macOS 14.0", "NSImage": "macOS 14.0", "UIKit": "iOS 17.0, tvOS 17.0",
            "SwiftUI": "iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0",
        ]
        let back: [String: String] = [
            "colors": "iOS 11.0, macOS 10.13, tvOS 11.0", "images": "iOS 11.0, macOS 10.7, tvOS 11.0",
            "NSColor": "macOS 10.13", "NSImage": "macOS 10.7", "UIKit": "iOS 11.0, tvOS 11.0",
            "SwiftUI": "iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0",
        ]
        return "@available(\((backDeploys ? back : modern)[key]!), *)"
    }

    public func swiftSource() -> String {
        var out = imports()
        out += "// MARK: - Color Symbols -\n\n\(availability("colors"))\nextension \(typePrefix)ColorResource {\n\n"
        emitResources(tree(colors), kind: "color", typeName: "ColorResource", indent: "    ", out: &out)
        out += "}\n\n"
        out += "// MARK: - Image Symbols -\n\n\(availability("images"))\nextension \(typePrefix)ImageResource {\n\n"
        emitResources(tree(images + symbolImages), kind: "image", typeName: "ImageResource", indent: "    ", out: &out)
        out += "}\n\n"
        if options.generateSwiftExtensions {
            out += extensions()
        }
        if backDeploys {
            out += backwardsDeploymentSupport()
        }
        return out
    }

    // MARK: Backwards deployment (deployment target below iOS 17 / macOS 14 / tvOS 17 / watchOS 10)

    static func resourceStruct(_ type: String, kind: String, article: String) -> String {
        """
        /// \(article.capitalized) \(kind) resource.
        struct \(type): Swift.Hashable, Swift.Sendable {

            /// An asset catalog \(kind) resource name.
            fileprivate let name: Swift.String

            /// An asset catalog \(kind) resource bundle.
            fileprivate let bundle: Foundation.Bundle

            /// Initialize \(article == "a" ? "a" : "an") `\(type)` with `name` and `bundle`.
            init(name: Swift.String, bundle: Foundation.Bundle) {
                self.name = name
                self.bundle = bundle
            }

        }


        """
    }

    func backwardsDeploymentSupport() -> String {
        var out = "// MARK: - Backwards Deployment Support -\n\n"
        out += Self.resourceStruct("ColorResource", kind: "color", article: "a")
        out += Self.resourceStruct("ImageResource", kind: "image", article: "an")
        var sections: [String] = []
        if options.frameworks.contains("AppKit") {
            sections.append("""
            #if canImport(AppKit)
            @available(macOS 10.13, *)
            @available(macCatalyst, unavailable)
            extension AppKit.NSColor {

                /// Initialize a `NSColor` with a color resource.
                convenience init(resource: ColorResource) {
                    self.init(named: NSColor.Name(resource.name), bundle: resource.bundle)!
                }

            }

            protocol _ACResourceInitProtocol {}
            extension AppKit.NSImage: _ACResourceInitProtocol {}

            @available(macOS 10.7, *)
            @available(macCatalyst, unavailable)
            extension _ACResourceInitProtocol {

                /// Initialize a `NSImage` with an image resource.
                init(resource: ImageResource) {
                    self = resource.bundle.image(forResource: NSImage.Name(resource.name))! as! Self
                }

            }
            #endif
            """)
        }
        if options.frameworks.contains("UIKit") {
            sections.append("""
            #if canImport(UIKit)
            @available(iOS 11.0, tvOS 11.0, *)
            @available(watchOS, unavailable)
            extension UIKit.UIColor {

                /// Initialize a `UIColor` with a color resource.
                convenience init(resource: ColorResource) {
            #if !os(watchOS)
                    self.init(named: resource.name, in: resource.bundle, compatibleWith: nil)!
            #else
                    self.init()
            #endif
                }

            }

            @available(iOS 11.0, tvOS 11.0, *)
            @available(watchOS, unavailable)
            extension UIKit.UIImage {

                /// Initialize a `UIImage` with an image resource.
                convenience init(resource: ImageResource) {
            #if !os(watchOS)
                    self.init(named: resource.name, in: resource.bundle, compatibleWith: nil)!
            #else
                    self.init()
            #endif
                }

            }
            #endif
            """)
        }
        if options.frameworks.contains("SwiftUI") {
            sections.append("""
            #if canImport(SwiftUI)
            @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
            extension SwiftUI.Color {

                /// Initialize a `Color` with a color resource.
                init(_ resource: ColorResource) {
                    self.init(resource.name, bundle: resource.bundle)
                }

            }

            @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
            extension SwiftUI.Image {

                /// Initialize an `Image` with an image resource.
                init(_ resource: ImageResource) {
                    self.init(resource.name, bundle: resource.bundle)
                }

            }
            #endif
            """)
        }
        // actool separates the framework sections with a blank line and ends the file without a newline.
        out += sections.joined(separator: "\n\n")
        return out
    }

    // MARK: Swift extensions (when --generate-swift-asset-symbol-extensions is YES)

    static let reservedColor: [String: Set<String>] = [
        "NSColor": ["black", "blue", "brown", "clear", "cyan", "darkGray", "gray", "green", "lightGray", "magenta", "orange", "purple", "red", "white", "yellow", "systemBlue", "systemBrown", "systemGray", "systemGreen", "systemIndigo", "systemOrange", "systemPink", "systemPurple", "systemRed", "systemTeal", "systemYellow", "systemMint", "systemCyan", "labelColor", "linkColor", "controlAccentColor"],
        "UIColor": ["black", "blue", "brown", "clear", "cyan", "darkGray", "darkText", "gray", "green", "label", "lightGray", "lightText", "link", "magenta", "orange", "placeholderText", "purple", "red", "separator", "opaqueSeparator", "systemBackground", "secondarySystemBackground", "tertiarySystemBackground", "systemFill", "secondarySystemFill", "tertiarySystemFill", "quaternarySystemFill", "systemGroupedBackground", "secondarySystemGroupedBackground", "tertiarySystemGroupedBackground", "secondaryLabel", "tertiaryLabel", "quaternaryLabel", "systemBlue", "systemBrown", "systemCyan", "systemGray", "systemGray2", "systemGray3", "systemGray4", "systemGray5", "systemGray6", "systemGreen", "systemIndigo", "systemMint", "systemOrange", "systemPink", "systemPurple", "systemRed", "systemTeal", "systemYellow", "tintColor", "white", "yellow"],
        "Color": ["accentColor", "black", "blue", "brown", "clear", "cyan", "gray", "green", "indigo", "mint", "orange", "pink", "primary", "purple", "red", "secondary", "teal", "white", "yellow"],
    ]
    static let reservedImage: [String: Set<String>] = [
        "NSImage": ["actionTemplate", "addTemplate", "applicationIcon", "bonjour", "caution", "computer", "everyone", "folder", "network", "touchBarAddTemplate"],
        "UIImage": ["actions", "add", "checkmark", "remove", "strokedCheckmark"],
    ]

    func flatSymbols(_ node: Node) -> [(Symbol, [String])] {
        var out: [(Symbol, [String])] = []
        func walk(_ n: Node, _ path: [String]) {
            for (_, child, symbol) in ordered(n) {
                if let child { walk(child, path + [Self.namespaceIdentifier(child.name)]) } else if let s = symbol { out.append((s, path)) }
            }
        }
        walk(node, [])
        return out
    }

    func emitExtensionMembers(_ node: Node, kind: String, type: String, shortType: String, guardCondition: String, isColor: Bool, indent: String, out: inout String) {
        let reserved = (isColor ? Self.reservedColor : Self.reservedImage)[shortType] ?? []
        for (_, child, symbol) in ordered(node) {
            if let child {
                out += "\(indent)/// The \"\(child.name)\" asset catalog resource namespace.\n"
                out += "\(indent)enum \(Self.namespaceIdentifier(child.name)) {\n\n"
                emitExtensionMembers(child, kind: kind, type: type, shortType: shortType, guardCondition: guardCondition, isColor: isColor, indent: indent + "    ", out: &out)
                out += "\(indent)}\n\n"
            } else if let s = symbol {
                let path = s.path.map { Self.namespaceIdentifier($0) + "." }.joined()
                if s.path.isEmpty && reserved.contains(s.swift) {
                    out += "\(indent)#warning(\"The \\\"\(s.name)\\\" \(kind) asset name resolves to a conflicting \(shortType) symbol \\\"\(s.swift)\\\". Try renaming the asset.\")\n\n"
                    continue
                }
                out += "\(indent)/// The \"\(s.name)\" asset catalog \(kind).\n"
                if shortType == "Color" {
                    out += "\(indent)static var \(s.swift): SwiftUI.Color { .init(.\(path)\(s.swift)) }\n\n"
                } else {
                    out += "\(indent)static var \(s.swift): \(type) {\n#if \(guardCondition)\n\(indent)    .init(resource: .\(path)\(s.swift))\n#else\n\(indent)    .init()\n#endif\n\(indent)}\n\n"
                }
            }
        }
    }

    func extensions() -> String {
        var out = "// MARK: - Color Symbol Extensions -\n\n"
        let colorTree = tree(colors)
        let imageTree = tree(images + symbolImages)
        if options.frameworks.contains("AppKit") {
            out += "#if canImport(AppKit)\n\(availability("NSColor"))\n@available(macCatalyst, unavailable)\nextension AppKit.NSColor {\n\n"
            emitExtensionMembers(colorTree, kind: "color", type: "AppKit.NSColor", shortType: "NSColor", guardCondition: "!targetEnvironment(macCatalyst)", isColor: true, indent: "    ", out: &out)
            out += "}\n#endif\n\n"
        }
        if options.frameworks.contains("UIKit") {
            out += "#if canImport(UIKit)\n\(availability("UIKit"))\n@available(watchOS, unavailable)\nextension UIKit.UIColor {\n\n"
            emitExtensionMembers(colorTree, kind: "color", type: "UIKit.UIColor", shortType: "UIColor", guardCondition: "!os(watchOS)", isColor: true, indent: "    ", out: &out)
            out += "}\n#endif\n\n"
        }
        if options.frameworks.contains("SwiftUI") {
            out += "#if canImport(SwiftUI)\n\(availability("SwiftUI"))\nextension SwiftUI.Color {\n\n"
            emitExtensionMembers(colorTree, kind: "color", type: "SwiftUI.Color", shortType: "Color", guardCondition: "", isColor: true, indent: "    ", out: &out)
            out += "}\n\n\(availability("SwiftUI"))\nextension SwiftUI.ShapeStyle where Self == SwiftUI.Color {\n\n"
            // ShapeStyle only gets top-level colors that don't collide with SwiftUI.Color statics.
            let top = Node("")
            top.symbols = colorTree.symbols.filter { !(Self.reservedColor["Color"] ?? []).contains($0.swift) }
            emitExtensionMembers(top, kind: "color", type: "SwiftUI.Color", shortType: "Color", guardCondition: "", isColor: true, indent: "    ", out: &out)
            out += "}\n#endif\n\n"
        }
        out += "// MARK: - Image Symbol Extensions -\n\n"
        if options.frameworks.contains("AppKit") {
            out += "#if canImport(AppKit)\n\(availability("NSImage"))\n@available(macCatalyst, unavailable)\nextension AppKit.NSImage {\n\n"
            emitExtensionMembers(imageTree, kind: "image", type: "AppKit.NSImage", shortType: "NSImage", guardCondition: "!targetEnvironment(macCatalyst)", isColor: false, indent: "    ", out: &out)
            out += "}\n#endif\n\n"
        }
        if options.frameworks.contains("UIKit") {
            out += "#if canImport(UIKit)\n\(availability("UIKit"))\n@available(watchOS, unavailable)\nextension UIKit.UIImage {\n\n"
            emitExtensionMembers(imageTree, kind: "image", type: "UIKit.UIImage", shortType: "UIImage", guardCondition: "!os(watchOS)", isColor: false, indent: "    ", out: &out)
            out += "}\n#endif\n\n"
        }
        out += "// MARK: - Thinnable Asset Support -\n\n"
        out += "\(availability("colors"))\n@available(watchOS, unavailable)\nextension \(typePrefix)ColorResource {\n\n    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {\n#if canImport(AppKit) && os(macOS)\n        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {\n            self.init(name: thinnableName, bundle: bundle)\n        } else {\n            return nil\n        }\n#elseif canImport(UIKit) && !os(watchOS)\n        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {\n            self.init(name: thinnableName, bundle: bundle)\n        } else {\n            return nil\n        }\n#else\n        return nil\n#endif\n    }\n\n}\n\n"
        out += "\(availability("images"))\n@available(watchOS, unavailable)\nextension \(typePrefix)ImageResource {\n\n    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {\n#if canImport(AppKit) && os(macOS)\n        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {\n            self.init(name: thinnableName, bundle: bundle)\n        } else {\n            return nil\n        }\n#elseif canImport(UIKit) && !os(watchOS)\n        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {\n            self.init(name: thinnableName, bundle: bundle)\n        } else {\n            return nil\n        }\n#else\n        return nil\n#endif\n    }\n\n}\n\n"
        return out
    }

    // MARK: Objective-C

    public func objcHeader() -> String {
        var out = "#import <Foundation/Foundation.h>\n\n#if __has_attribute(swift_private)\n#define AC_SWIFT_PRIVATE __attribute__((swift_private))\n#else\n#define AC_SWIFT_PRIVATE\n#endif\n\n"
        if !colors.isEmpty {
            out += "/// The resource bundle ID.\nstatic NSString * const ACBundleID AC_SWIFT_PRIVATE = @\"\(options.bundleIdentifier)\";\n\n"
        }
        // Sorted by the name without its namespace, in byte order.
        func sorted(_ s: [Symbol]) -> [Symbol] {
            s.sorted { Array($0.leaf.utf8).lexicographicallyPrecedes(Array($1.leaf.utf8)) || ($0.leaf == $1.leaf && $0.name < $1.name) }
        }
        for s in sorted(colors) {
            out += "/// The \"\(s.name)\" asset catalog color resource.\nstatic NSString * const ACColorName\(Self.objcIdentifier(s.name)) AC_SWIFT_PRIVATE = @\"\(s.name)\";\n\n"
        }
        for s in sorted(images) + sorted(symbolImages) {
            out += "/// The \"\(s.name)\" asset catalog image resource.\nstatic NSString * const ACImageName\(Self.objcIdentifier(s.name)) AC_SWIFT_PRIVATE = @\"\(s.name)\";\n\n"
        }
        out += "#undef AC_SWIFT_PRIVATE\n"
        return out
    }

    // MARK: Index

    public func indexPlist() throws -> Data {
        func entries(_ list: [Symbol], prefix: String) -> [[String: Any]] {
            list.sorted { $0.name.lowercased() < $1.name.lowercased() }.map { s in
                ["catalogPath": s.catalog.path, "objcSymbol": prefix + Self.objcIdentifier(s.leaf), "relativePath": s.relativePath, "swiftSymbol": s.swift]
            }
        }
        let plist: [String: Any] = [
            "colors": entries(colors, prefix: "ACColorName"),
            "images": entries(images + symbolImages, prefix: "ACImageName"),
            "symbols": [[String: Any]](),
        ]
        return PlistXML.encode(plist)
    }
}
