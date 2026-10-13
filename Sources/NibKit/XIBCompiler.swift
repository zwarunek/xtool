import Foundation

public struct XIBDiagnostic: CustomStringConvertible {
    public enum Severity: String { case error, warning, note }
    public let severity: Severity
    public let line: Int?
    public let message: String

    public var description: String { "\(severity.rawValue): \(message)" }
}

public struct XIBCompileOptions {
    /// `--module`: the module that `customModuleProvider="target"` classes live in.
    public var module: String?
    /// The xib is localized (it lives in an .lproj folder): user-visible strings are archived as
    /// NSLocalizableString so UIKit can look them up in the companion .strings table.
    public var localizable: Bool

    public init(module: String? = nil, localizable: Bool = false) {
        self.module = module
        self.localizable = localizable
    }
}

public struct XIBCompileResult {
    public let nib: [UInt8]
    public let root: NibObject
    public let diagnostics: [XIBDiagnostic]
    /// Content for `--output-partial-info-plist` (custom fonts the xib uses go to UIAppFonts).
    public let partialInfoPlist: [String: Any]
}

public enum XIBCompileError: Error, CustomStringConvertible {
    case unsupportedDocument(String)
    case invalid(String, line: Int?)

    public var description: String {
        switch self {
        case .unsupportedDocument(let message): return message
        case .invalid(let message, let line): return line.map { "line \($0): \(message)" } ?? message
        }
    }
}

/// Compiles an iOS `.xib` (Interface Builder document version 3) into a NIBArchive that UINib loads.
///
/// ibtool builds the nib by instantiating real UIKit objects and archiving them, so the archive holds UIKit's
/// encoding of each class, not the xib's attributes. This compiler writes the same keys UIKit's
/// `encodeWithCoder:` writes for each supported class, with UIKit defaults filled in from `UIKitTables`.
public final class XIBCompiler {
    let document: XMLElement2
    let options: XIBCompileOptions
    var diagnostics: [XIBDiagnostic] = []

    var elementsByID: [String: XMLElement2] = [:]
    var objectsByID: [String: NibObject] = [:]
    var valueObjects: [String: NibObject] = [:]
    /// UIViewSafeAreaLayoutGuide objects, keyed by the xib id of the `<viewLayoutGuide key="safeArea">`.
    var safeAreaGuides: [String: NibObject] = [:]
    var safeAreaOwners: [String: XMLElement2] = [:]
    var keyValuePairs: [NibObject] = []
    var allObjects: [NibObject] = []
    var outlets: [(label: String, source: NibObject, destination: NibObject, order: Int)] = []
    var collections: [(label: String, source: NibObject, destinations: [NibObject], appends: Bool, className: String)] = []
    var events: [(label: String, source: NibObject, destination: NibObject, mask: Int?, order: Int)] = []
    var appFonts: [String] = []
    var resourceColors: [String: XMLElement2] = [:]
    var customFontNames: Set<String> = []

    public static func compile(xib data: Data, options: XIBCompileOptions = .init()) throws -> XIBCompileResult {
        let root = try XMLTreeBuilder.parse(data)
        let compiler = XIBCompiler(document: root, options: options)
        let nibRoot = try compiler.run()
        let plist: [String: Any] = compiler.appFonts.isEmpty ? [:] : ["UIAppFonts": compiler.appFonts]
        return XIBCompileResult(nib: NibArchive.encode(root: nibRoot), root: nibRoot,
                                diagnostics: compiler.diagnostics, partialInfoPlist: plist)
    }

    init(document: XMLElement2, options: XIBCompileOptions) {
        self.document = document
        self.options = options
    }

    func warn(_ message: String, _ element: XMLElement2? = nil) {
        diagnostics.append(XIBDiagnostic(severity: .warning, line: element?.line, message: message))
    }

    // MARK: Driver

    // swiftlint:disable:next cyclomatic_complexity
    func run() throws -> NibObject {
        guard document.name == "document" else {
            throw XIBCompileError.unsupportedDocument("only Interface Builder 3 documents (<document>) are supported")
        }
        let type = document["type"] ?? ""
        guard type.hasPrefix("com.apple.InterfaceBuilder3.CocoaTouch") && type.hasSuffix(".XIB") && !type.contains("Storyboard") else {
            throw XIBCompileError.unsupportedDocument("unsupported document type '\(type)'; only iOS xibs are supported")
        }
        guard let objects = document.child(named: "objects") else {
            throw XIBCompileError.invalid("missing <objects>", line: document.line)
        }
        index(document)
        for fontFile in document.child(named: "customFonts")?.children(named: "array") ?? [] {
            if let file = fontFile["key"] { appFonts.append(file) }
            for name in fontFile.children(named: "string") {
                if let fontName = name.text?.trimmingCharacters(in: .whitespacesAndNewlines) { customFontNames.insert(fontName) }
            }
        }
        for systemColor in document.child(named: "resources")?.children(named: "systemColor") ?? [] {
            if let name = systemColor["name"], let color = systemColor.child(named: "color") {
                resourceColors[name] = color
            }
        }

        var topLevel: [NibObject] = []
        for element in objects.children {
            guard let object = self.object(for: element) else { continue }
            topLevel.append(object)
        }
        // UINibObjectsKey lists every Interface Builder object; UIKit sends awakeFromNib to them.
        for element in objects.children { collectAllObjects(element) }

        for element in objects.children { collectConnections(element) }

        let root = NibObject("NSObject")
        root.add("UINibTopLevelObjectsKey", .object(array(topLevel)))
        root.add("UINibObjectsKey", .object(array(allObjects)))
        root.add("UINibConnectionsKey", .object(array(connectionObjects())))
        let empty = array([])
        root.add("UINibVisibleWindowsKey", .object(empty))
        root.add("UINibAccessibilityConfigurationsKey", .object(empty))
        let traitLists = objects.children.compactMap { traitStorageList($0) }
        root.add("UINibTraitStorageListsKey", .object(traitLists.isEmpty ? empty : array(traitLists)))
        root.add("UINibKeyValuePairsKey", .object(keyValuePairs.isEmpty ? empty : array(keyValuePairs)))
        // ibtool marks nibs whose objects are all plain UIViews (or UIView subclasses by custom class).
        if objects.children.allSatisfy({ onlyPlainViews($0) }) {
            root.add("IBUINibLNEVersionKey", .int(1))
        }
        return root
    }

    func onlyPlainViews(_ element: XMLElement2) -> Bool {
        switch element.name {
        case "placeholder": return true
        case "view":
            return (element.child(named: "subviews")?.children ?? []).allSatisfy { onlyPlainViews($0) }
        default: return false
        }
    }

    func index(_ element: XMLElement2) {
        if let id = element["id"] { elementsByID[id] = element }
        if element.name == "viewLayoutGuide", element["key"] == "safeArea", let id = element["id"], let owner = element.parent {
            safeAreaOwners[id] = owner
        }
        for child in element.children { index(child) }
    }

    /// The nib object for an Interface Builder object, created on first use so references share it.
    func object(for element: XMLElement2) -> NibObject? {
        if let id = element["id"], let existing = objectsByID[id] { return existing }
        if element.name == "viewLayoutGuide", let id = element["id"] {
            return safeAreaGuide(id: id)
        }
        let className = uikitClass(element)
        guard let className else {
            warn("unsupported object <\(element.name)> was left out of the nib", element)
            return nil
        }
        let customClass = element["customClass"].map { qualifiedClassName($0, element) }
        let isPlaceholder = element.name == "placeholder"
        let object = NibObject(customClass != nil && !isPlaceholder ? "UIClassSwapper" : className,
                               fallbacks: fallbacks(className))
        if let id = element["id"] { objectsByID[id] = object }
        encodeObject(element, className: className, into: object)
        if let customClass, !isPlaceholder {
            object.add("UIClassName", .object(string(customClass)))
            object.add("UIOriginalClassName", .object(string(className)))
        }
        encodeUserDefinedRuntimeAttributes(element, object: object)
        return object
    }

    func object(id: String, from element: XMLElement2) -> NibObject? {
        if let existing = objectsByID[id] { return existing }
        if let target = elementsByID[id] { return self.object(for: target) }
        warn("reference to unknown object id '\(id)'", element)
        return nil
    }

    /// Swift classes are archived under their mangled runtime name, e.g. `_TtC6Module5Class`.
    func qualifiedClassName(_ name: String, _ element: XMLElement2) -> String {
        var module = element["customModule"]
        if element["customModuleProvider"] == "target" { module = options.module ?? module }
        guard let module, !module.isEmpty else { return name }
        let components = name.split(separator: ".").map(String.init)
        var mangled = "_TtC\(module.utf8.count)\(module)"
        for component in components { mangled += "\(component.utf8.count)\(component)" }
        return components.count == 1 ? mangled : "_TtCC" + mangled.dropFirst(4)
    }

    func fallbacks(_ className: String) -> [String] {
        switch className {
        case "UITableViewCellContentView": return ["UIView"]
        default: return []
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func uikitClass(_ element: XMLElement2) -> String? {
        switch element.name {
        case "placeholder": return "UIProxyObject"
        case "view": return "UIView"
        case "label": return "UILabel"
        case "button": return "UIButton"
        case "textField": return "UITextField"
        case "switch": return "UISwitch"
        case "slider": return "UISlider"
        case "stepper": return "UIStepper"
        case "imageView": return "UIImageView"
        case "tableView": return "UITableView"
        case "tableViewCell": return "UITableViewCell"
        case "tableViewCellContentView": return "UITableViewCellContentView"
        case "searchBar": return "UISearchBar"
        case "pinchGestureRecognizer": return "UIPinchGestureRecognizer"
        case "tapGestureRecognizer": return "UITapGestureRecognizer"
        case "panGestureRecognizer": return "UIPanGestureRecognizer"
        case "swipeGestureRecognizer": return "UISwipeGestureRecognizer"
        case "pongPressGestureRecognizer": return "UILongPressGestureRecognizer"
        case "scrollView": return "UIScrollView"
        case "activityIndicatorView": return "UIActivityIndicatorView"
        default: return nil
        }
    }

    // MARK: Objects

    func encodeObject(_ element: XMLElement2, className: String, into object: NibObject) {
        switch element.name {
        case "placeholder":
            object.add("UIProxiedObjectIdentifier", .object(string(element["placeholderIdentifier"] ?? "")))
        case "pinchGestureRecognizer", "tapGestureRecognizer", "panGestureRecognizer", "swipeGestureRecognizer",
             "pongPressGestureRecognizer": // sic: Interface Builder's element name for long press
            encodeGestureRecognizer(element, into: object)
        default:
            encodeView(element, className: className, into: object)
        }
        if element.name != "placeholder" {
            checkAttributes(element)
        }
    }

    func encodeGestureRecognizer(_ element: XMLElement2, into object: NibObject) {
        object.add("UIGestureRecognizer.allowedTouchTypes", .int(15))
        object.add("UIGestureRecognizer.requiresExclusiveTouchType", .bool(true))
        if element["enabled"] == "NO" { object.add("UIGestureRecognizer.enabled", .bool(false)) }
        if element["cancelsTouchesInView"] == "NO" { object.add("UIGestureRecognizer.cancelsTouchesInView", .bool(false)) }
        if element["delaysTouchesBegan"] == "YES" { object.add("UIGestureRecognizer.delaysTouchesBegan", .bool(true)) }
        if element["delaysTouchesEnded"] == "NO" { object.add("UIGestureRecognizer.delaysTouchesEnded", .bool(false)) }
        if element.name == "tapGestureRecognizer" {
            let imp = NibObject("UITapRecognizer")
            if let taps = element["numberOfTapsRequired"].flatMap(Int.init), taps != 1 {
                imp.add("UITapRecognizer.numberOfTapsRequired", .ints(taps))
            }
            if let touches = element["numberOfTouchesRequired"].flatMap(Int.init), touches != 1 {
                imp.add("UITapRecognizer.numberOfTouchesRequired", .ints(touches))
            }
            object.add("UITapGestureRecognizer._imp", .object(imp))
        }
    }
}
