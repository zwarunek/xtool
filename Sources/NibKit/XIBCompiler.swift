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
        case "pinchGestureRecognizer", "tapGestureRecognizer", "panGestureRecognizer", "swipeGestureRecognizer", "pongPressGestureRecognizer":
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

    // MARK: Views

    struct Frame {
        var x: Double, y: Double, width: Double, height: Double
    }

    func frameOf(_ element: XMLElement2) -> Frame {
        var frame: Frame
        if let rect = element.child(named: "rect", key: "frame") {
            frame = Frame(x: rect.double("x") ?? 0, y: rect.double("y") ?? 0,
                          width: rect.double("width") ?? 0, height: rect.double("height") ?? 0)
        } else if let inset = element.child(named: "frame", key: "frameInset") {
            // Older documents give frames as insets from the superview.
            let parentView = element.parent.flatMap { $0.name == "subviews" ? $0.parent : $0 }
            let parent = parentView.map { frameOf($0) } ?? Frame(x: 0, y: 0, width: 0, height: 0)
            let minX = inset.double("minX") ?? 0, minY = inset.double("minY") ?? 0
            let width = inset.double("width") ?? (parent.width - minX - (inset.double("maxX") ?? 0))
            let height = inset.double("height") ?? (parent.height - minY - (inset.double("maxY") ?? 0))
            let x = inset["minX"] != nil ? minX : parent.width - width - (inset.double("maxX") ?? 0)
            let y = inset["minY"] != nil ? minY : parent.height - height - (inset.double("maxY") ?? 0)
            frame = Frame(x: x, y: y, width: width, height: height)
        } else {
            frame = Frame(x: 0, y: 0, width: 0, height: 0)
        }
        // Top-level views without freeform metrics take the size of the document's device.
        if element.parent?.name == "objects", element.name == "view",
           element.child(named: "freeformSimulatedSizeMetrics", key: "simulatedDestinationMetrics") == nil {
            let size = deviceSize()
            frame.width = size.width
            frame.height = size.height
        }
        return frame
    }

    func deviceSize() -> (width: Double, height: Double) {
        let device = document.child(named: "device")
        let sizes: [String: (Double, Double)] = [
            "retina3_5": (320, 480), "retina4_0": (320, 568), "retina4_7": (375, 667), "retina5_5": (414, 736),
            "retina5_9": (375, 812), "retina6_1": (414, 896), "retina6_5": (414, 896), "retina6_0": (390, 844),
            "retina6_7": (428, 926), "retina6_12": (393, 852), "retina6_72": (430, 932), "retina6_3": (402, 874),
            "retina6_9": (440, 956), "iPad": (768, 1024), "ipad9_7": (768, 1024), "ipad10_2": (810, 1080),
            "ipad10_5": (834, 1112), "ipad10_9rounded": (820, 1180), "ipad11_0rounded": (834, 1194),
            "ipad12_9": (1024, 1366), "ipad12_9rounded": (1024, 1366),
        ]
        var size = sizes[device?["id"] ?? "retina6_12"] ?? (393, 852)
        if device?["orientation"] == "landscape" { size = (size.1, size.0) }
        return (size.0, size.1)
    }

    func encodeView(_ element: XMLElement2, className: String, into object: NibObject) {
        var frame = frameOf(element)
        if className == "UISwitch" {
            // UIKit gives UISwitch its own size; ibtool restores the xib frame with a key-value pair.
            keyValuePairs.append(keyValuePair(object: object, keyPath: "frame",
                                              value: rectValue(frame)))
            frame.width = UIKitTables.switchSize.width
            frame.height = UIKitTables.switchSize.height
        }
        object.add("UIBounds", doubles([0, 0, frame.width, frame.height]))
        object.add("UICenter", doubles([frame.x + frame.width / 2, frame.y + frame.height / 2]))

        var subviews: [NibObject] = element.child(named: "subviews")?.children.compactMap { self.object(for: $0) } ?? []
        var cellContentView: NibObject?
        if className == "UITableViewCell" {
            if let contentElement = element.child(named: "tableViewCellContentView", key: "contentView"),
               let content = self.object(for: contentElement) {
                cellContentView = content
                subviews.insert(content, at: 0)
            }
            subviews.append(cellSeparatorView(cellFrame: frame))
        }
        if !subviews.isEmpty {
            object.add("UISubviews", .object(array(subviews, mutable: true)))
        }

        var background = element.child(named: "color", key: "backgroundColor").map { color($0) }
        if background == nil, className == "UITableViewCell" {
            background = systemColor("tableCellPlainBackgroundColor")
        }
        if let background {
            object.add("UIBackgroundColor", .object(background))
            if className == "UITableViewCell" {
                object.add("UIDidEncodeCompatibilityBackgroundColor", .bool(true))
            }
        }
        object.add("UIDeepDrawRect", .bool(true))
        if element.bool("multipleTouchEnabled") == true {
            object.add("UIMultipleTouchEnabled", .bool(true))
        }
        if element.bool("opaque") != false {
            object.add("UIOpaque", .bool(true))
        }
        if let tag = element["tag"].flatMap(Int.init), tag != 0 {
            object.add("UITag", .ints(tag))
        }
        if element.bool("userInteractionEnabled") == false {
            object.add("UIUserInteractionDisabled", .bool(true))
        }
        if element.bool("hidden") == true {
            object.add("UIHidden", .bool(true))
        }
        if let alpha = element.double("alpha"), alpha != 1 {
            object.add("UIAlpha", .float(Float(alpha)))
        }
        if element.bool("autoresizesSubviews") != false {
            object.add("UIAutoresizeSubviews", .bool(true))
        }
        let mask = autoresizingMask(element)
        if mask != 0 {
            object.add("UIAutoresizingMask", .ints(mask))
        }
        if element.bool("clearsContextBeforeDrawing") == false {
            object.add("UIClearsContextBeforeDrawing", .bool(false))
        }
        if let mode = element["contentMode"] {
            if let value = UIKitTables.contentModes[mode] {
                if value != 0 { object.add("UIContentMode", .ints(value)) }
            } else {
                warn("unknown contentMode '\(mode)'", element)
            }
        }
        if element.bool("clipsSubviews") == true {
            object.add("UIClipsToBounds", .bool(true))
        }
        if let tint = element.child(named: "color", key: "tintColor") {
            object.add("UITintColor", .object(color(tint)))
        }
        if element.bool("translatesAutoresizingMaskIntoConstraints") == false, element.bool("fixedFrame") != true {
            object.add("UIViewDoesNotTranslateAutoresizingMaskIntoConstraints", .bool(true))
        }
        let constraints = element.child(named: "constraints")?.children(named: "constraint")
            .compactMap { constraint($0, owner: element, ownerObject: object) } ?? []
        if !constraints.isEmpty {
            object.add("UIViewAutolayoutConstraints", .object(array(constraints, mutable: true)))
        }
        encodePriorities(element, className: className, into: object)
        if let guideElement = element.child(named: "viewLayoutGuide", key: "safeArea"), let id = guideElement["id"] {
            let guide = safeAreaGuide(id: id)
            object.add("UIViewLayoutGuides", .object(array([guide], mutable: true)))
        }
        if let margins = element.child(named: "edgeInsets", key: "layoutMargins") {
            object.add("UIViewLayoutMargins", doubles([margins.double("top") ?? 0, margins.double("left") ?? 0,
                                                       margins.double("bottom") ?? 0, margins.double("right") ?? 0]))
        }
        object.add("UIViewSemanticContentAttribute", .int(0))
        object.add("UIViewLargeContentStoredProperties", .null)

        switch className {
        case "UILabel": encodeLabel(element, into: object)
        case "UIButton": encodeButton(element, into: object)
        case "UITextField": encodeTextField(element, into: object)
        case "UISwitch": encodeSwitch(element, into: object)
        case "UISlider": encodeSlider(element, into: object)
        case "UIStepper": encodeStepper(element, into: object)
        case "UIImageView": encodeImageView(element, into: object)
        case "UITableView": encodeTableView(element, into: object)
        case "UITableViewCell": encodeTableViewCell(element, frame: frame, contentView: cellContentView, into: object)
        case "UISearchBar": encodeSearchBar(element, into: object)
        case "UIView", "UITableViewCellContentView": break
        default:
            warn("<\(element.name)> is archived as a plain \(className) without its own properties", element)
        }
    }

    func autoresizingMask(_ element: XMLElement2) -> Int {
        guard let mask = element.child(named: "autoresizingMask", key: "autoresizingMask") else {
            // Interface Builder leaves the element out for the default, flexible right and bottom margins.
            return element.name == "tableViewCellContentView" ? 0 : 36
        }
        var value = 0
        if mask.bool("flexibleMinX") == true { value |= 1 }
        if mask.bool("widthSizable") == true { value |= 2 }
        if mask.bool("flexibleMaxX") == true { value |= 4 }
        if mask.bool("flexibleMinY") == true { value |= 8 }
        if mask.bool("heightSizable") == true { value |= 16 }
        if mask.bool("flexibleMaxY") == true { value |= 32 }
        return value
    }

    func encodePriorities(_ element: XMLElement2, className: String, into object: NibObject) {
        let hugging = (element.double("horizontalHuggingPriority") ?? 250, element.double("verticalHuggingPriority") ?? 250)
        let defaultHugging = UIKitTables.defaultHugging(className)
        if hugging != defaultHugging {
            object.add("UIViewContentHuggingPriority", .object(string("{\(format(hugging.0)), \(format(hugging.1))}")))
        }
        let resistance = (element.double("horizontalCompressionResistancePriority") ?? 750,
                          element.double("verticalCompressionResistancePriority") ?? 750)
        let defaultResistance = UIKitTables.defaultCompressionResistance(className)
        if resistance != defaultResistance {
            object.add("UIViewContentCompressionResistancePriority",
                       .object(string("{\(format(resistance.0)), \(format(resistance.1))}")))
        }
    }

    func cellSeparatorView(cellFrame: Frame) -> NibObject {
        let separator = NibObject("_UITableViewCellSeparatorView")
        let inset = 8.0
        separator.add("UIBounds", doubles([0, 0, cellFrame.width - 2 * inset, 1]))
        separator.add("UICenter", doubles([cellFrame.width / 2, cellFrame.height - 0.5]))
        separator.add("UIDeepDrawRect", .bool(true))
        separator.add("UIOpaque", .bool(true))
        separator.add("UIAutoresizeSubviews", .bool(true))
        separator.add("UIViewSemanticContentAttribute", .int(0))
        separator.add("UIViewLargeContentStoredProperties", .null)
        return separator
    }

    func encodeLabel(_ element: XMLElement2, into object: NibObject) {
        if let text = element["text"] ?? element.child(named: "string", key: "text")?.text {
            object.add("UIText", .object(localizable(text, element, "text")))
        }
        let fontDescription = element.child(named: "fontDescription", key: "fontDescription")
        let fontObject = font(fontDescription, defaultSize: 17)
        let pointSize = fontDescription?.double("pointSize") ?? 17
        object.add("UIFont", .object(fontObject))
        let textColor = element.child(named: "color", key: "textColor").map { color($0) } ?? systemColor("labelColor")
        object.add("UITextColor", .object(textColor))
        if let shadow = element.child(named: "color", key: "shadowColor") {
            object.add("UIShadowColor", .object(color(shadow)))
        }
        if let offset = element.child(named: "size", key: "shadowOffset") {
            object.add("UIShadowOffset", doubles([offset.double("width") ?? 0, offset.double("height") ?? 0]))
        } else {
            object.add("UIShadowOffset", doubles([0, -1]))
        }
        // Interface Builder writes adjustsFontSizeToFit="NO" when it is off; a missing attribute means on.
        let adjusts = element.bool("adjustsFontSizeToFit") ?? true
        var minimumScaleFactor = element.double("minimumScaleFactor")
        if adjusts {
            object.add("UIAdjustsFontSizeToFit", .bool(true))
            if let minimumFontSize = element.double("minimumFontSize") {
                object.add("UIMinimumFontSize", .float(Float(minimumFontSize)))
                if minimumScaleFactor == nil, pointSize > 0 { minimumScaleFactor = minimumFontSize / pointSize }
            } else if let factor = minimumScaleFactor {
                object.add("UIMinimumFontSize", .float(Float((factor * pointSize).rounded())))
            }
        }
        if let mode = element["lineBreakMode"], let value = UIKitTables.lineBreakModes[mode], value != 4 {
            object.add("UILineBreakMode", .ints(value))
        }
        if let lines = element["numberOfLines"].flatMap(Int.init), lines != 1 {
            object.add("UINumberOfLines", .ints(lines))
        }
        object.add("UITextAlignment", .ints(textAlignment(element)))
        if adjusts, let scale = minimumScaleFactor {
            object.add("UIMinimumScaleFactor", .float(Float(scale)))
        }
        if element.bool("adjustsLetterSpacingToFitWidth") == true {
            object.add("UIAdjustsLetterSpacingToFit", .bool(true))
        }
        if let baseline = element["baselineAdjustment"], baseline != "alignBaselines" {
            object.add("UIBaselineAdjustment", .ints(baseline == "alignCenters" ? 1 : 2))
        }
        object.add("UIDisableUpdateTextColorOnTraitCollectionChange", .bool(true))
    }

    /// UIKit archives natural alignment as 0, the same as left.
    func textAlignment(_ element: XMLElement2) -> Int {
        let value = UIKitTables.textAlignments[element["textAlignment"] ?? "natural"] ?? 4
        return value == 4 ? 0 : value
    }

    func encodeButton(_ element: XMLElement2, into object: NibObject) {
        if let horizontal = element["contentHorizontalAlignment"], let value = UIKitTables.contentHorizontalAlignments[horizontal], value != 0 {
            object.add("UIContentHorizontalAlignment", .ints(value))
        }
        if let vertical = element["contentVerticalAlignment"], let value = UIKitTables.contentVerticalAlignments[vertical], value != 0 {
            object.add("UIContentVerticalAlignment", .ints(value))
        }
        var states: [(Int, NibObject)] = []
        for state in element.children(named: "state") {
            guard let key = state["key"], let stateValue = UIKitTables.controlStates[key] else { continue }
            let content = NibObject("UIButtonContent")
            if let title = state["title"] { content.add("UITitle", .object(localizable(title, element, "\(key)Title"))) }
            if let image = state["image"] { content.add("UIImage", .object(imageReference(image))) }
            if let background = state["backgroundImage"] { content.add("UIBackgroundImage", .object(imageReference(background))) }
            if let titleColor = state.child(named: "color", key: "titleColor") {
                content.add("UITitleColor", .object(color(titleColor)))
            }
            if let shadow = state.child(named: "color", key: "titleShadowColor") {
                content.add("UIShadowColor", .object(color(shadow)))
            }
            states.append((stateValue, content))
        }
        if !states.isEmpty {
            let dictionary = NibObject("NSMutableDictionary")
            dictionary.add("NSInlinedValue", .bool(true))
            for (state, content) in states {
                dictionary.add("UINibEncoderEmptyKey", .object(number(state)))
                dictionary.add("UINibEncoderEmptyKey", .object(content))
            }
            object.add("UIButtonStatefulContent", .object(dictionary))
        }
        object.add("UIAdjustsImageWhenHighlighted", .bool(element.bool("adjustsImageWhenHighlighted") ?? true))
        object.add("UIAdjustsImageWhenDisabled", .bool(element.bool("adjustsImageWhenDisabled") ?? true))
        let type = UIKitTables.buttonTypes[element["buttonType"] ?? "custom"] ?? 0
        if type != 0 {
            object.add("UIButtonType", .ints(type))
        }
        // Custom buttons default to an 18 point system font, system buttons to 15 points.
        object.add("UIFont", .object(font(element.child(named: "fontDescription", key: "fontDescription"),
                                          defaultSize: type == 0 ? 18 : 15)))
        if let insets = element.child(named: "inset", key: "imageEdgeInsets") {
            object.add("UIImageEdgeInsets", doubles([insets.double("minY") ?? 0, insets.double("minX") ?? 0,
                                                     insets.double("maxY") ?? 0, insets.double("maxX") ?? 0]))
        }
        object.add("UIButtonConfiguration", .null)
    }

    func encodeTextField(_ element: XMLElement2, into object: NibObject) {
        if element.bool("selected") == true { object.add("UISelected", .bool(true)) }
        if element.bool("enabled") == false { object.add("UIDisabled", .bool(true)) }
        let horizontal = UIKitTables.contentHorizontalAlignments[element["contentHorizontalAlignment"] ?? "left"] ?? 1
        if horizontal != 0 { object.add("UIContentHorizontalAlignment", .ints(horizontal)) }
        if let vertical = element["contentVerticalAlignment"], let value = UIKitTables.contentVerticalAlignments[vertical], value != 0 {
            object.add("UIContentVerticalAlignment", .ints(value))
        }
        if let text = element["text"] { object.add("UIText", .object(localizable(text, element, "text"))) }
        object.add("UIFont", .object(font(element.child(named: "fontDescription", key: "fontDescription"), defaultSize: 14)))
        if let placeholder = element["placeholder"] {
            object.add("UIPlaceholder", .object(localizable(placeholder, element, "placeholder")))
        }
        object.add("UITextAlignment", .ints(textAlignment(element)))
        let textColor = element.child(named: "color", key: "textColor").map { color($0) } ?? systemColor("labelColor")
        object.add("UITextColor", .object(textColor))
        let border = UIKitTables.borderStyles[element["borderStyle"] ?? "none"] ?? 0
        if border != 0 { object.add("UIBorderStyle", .ints(border)) }
        if element.bool("adjustsFontSizeToFit") != false { object.add("UIAdjustsFontSizeToFit", .bool(true)) }
        object.add("UIMinimumFontSize", .float(Float(element.double("minimumFontSize") ?? 17)))
        let clear = UIKitTables.clearButtonModes[element["clearButtonMode"] ?? "never"] ?? 0
        if clear != 0 { object.add("UIClearButtonMode", .ints(clear)) }
        object.add("UIClearButtonOffset", doubles([3, 1]))
        encodeTextInputTraits(element.child(named: "textInputTraits", key: "textInputTraits"), into: object, forSearchBar: false)
        object.add("UIDisableTextColorUpdateOnTraitCollectionChange", .bool(true))
        object.add("UIRoundedRectBackgroundCornerRadius", .double(0))
    }

    func encodeTextInputTraits(_ traits: XMLElement2?, into object: NibObject, forSearchBar: Bool) {
        let autocapitalization = traits?["autocapitalizationType"].flatMap { UIKitTables.autocapitalizationTypes[$0] }
        if let autocapitalization, autocapitalization != 0 {
            object.add("UIAutocapitalizationType", .ints(autocapitalization))
        }
        let keyboard = traits?["keyboardType"].flatMap { UIKitTables.keyboardTypes[$0] } ?? 0
        let spellChecking = traits?["spellCheckingType"].flatMap { UIKitTables.traitTriState[$0] } ?? 0
        let autocorrection = traits?["autocorrectionType"].flatMap { UIKitTables.traitTriState[$0] } ?? 0
        // UISearchBar and UITextField archive these traits in different orders.
        if forSearchBar {
            if keyboard != 0 { object.add("UIKeyboardType", .ints(keyboard)) }
            if spellChecking != 0 { object.add("UISpellCheckingType", .ints(spellChecking)) }
            if autocorrection != 0 { object.add("UIAutocorrectionType", .ints(autocorrection)) }
        } else {
            if autocorrection != 0 { object.add("UIAutocorrectionType", .ints(autocorrection)) }
            if spellChecking != 0 { object.add("UISpellCheckingType", .ints(spellChecking)) }
            if keyboard != 0 { object.add("UIKeyboardType", .ints(keyboard)) }
        }
        if let returnKey = traits?["returnKeyType"].flatMap({ UIKitTables.returnKeyTypes[$0] }), returnKey != 0 {
            object.add("UIReturnKeyType", .ints(returnKey))
        }
        let enablesReturn = traits?.bool("enablesReturnKeyAutomatically") ?? false
        if forSearchBar {
            object.add("UIEnablesReturnKeyAutomatically", .bool(enablesReturn))
            object.add("UISecureTextEntry", .bool(traits?.bool("secureTextEntry") ?? false))
        } else {
            if enablesReturn { object.add("UIEnablesReturnKeyAutomatically", .bool(true)) }
            if traits?.bool("secureTextEntry") == true { object.add("UISecureTextEntry", .bool(true)) }
        }
        for (attribute, key) in [("smartInsertDeleteType", "UITextSmartInsertDeleteType"),
                                 ("smartQuotesType", "UITextSmartQuotesType"),
                                 ("smartDashesType", "UITextSmartDashesType")] {
            if let value = traits?[attribute].flatMap({ UIKitTables.traitTriState[$0] }), value != 0 {
                object.add(key, .ints(value))
            }
        }
    }

    func encodeSwitch(_ element: XMLElement2, into object: NibObject) {
        object.add("UISwitchEnabled", .bool(element.bool("enabled") ?? true))
        if element.bool("on") == true {
            object.add("UISwitchOn", .bool(true))
        }
        if let tint = element.child(named: "color", key: "onTintColor") {
            object.add("UIOnTintColor", .object(color(tint)))
        }
    }

    func encodeStepper(_ element: XMLElement2, into object: NibObject) {
        for (attribute, key, defaultValue) in [("value", "UIValue", 0.0), ("minimumValue", "UIMinimumValue", 0),
                                               ("maximumValue", "UIMaximumValue", 100), ("stepValue", "UIStepValue", 1)] {
            if let value = element.double(attribute), value != defaultValue {
                object.add(key, .double(value))
            }
        }
    }

    func encodeSlider(_ element: XMLElement2, into object: NibObject) {
        if let value = element.double("value"), value != 0 {
            object.add("UIValue", .float(Float(value)))
        }
        if let minimum = element.double("minValue"), minimum != 0 {
            object.add("UIMinValue", .float(Float(minimum)))
        }
        if let maximum = element.double("maxValue"), maximum != 1 {
            object.add("UIMaxValue", .float(Float(maximum)))
        }
        if element.bool("continuous") == false {
            object.add("UIContinuous", .bool(false))
        }
        object.add("UIBehavioralStyle", .int(0))
    }

    func encodeImageView(_ element: XMLElement2, into object: NibObject) {
        if let image = element["image"] {
            object.add("UIImage", .object(imageReference(image)))
        }
        if let highlighted = element["highlightedImage"] {
            object.add("UIHighlightedImage", .object(imageReference(highlighted)))
        }
    }

    /// Images are looked up by name at load time. ibtool is not given the asset catalogs, so it archives
    /// named images at 1x1 like this.
    func imageReference(_ name: String) -> NibObject {
        let key = "UIImageNibPlaceholder|" + name
        if let existing = valueObjects[key] { return existing }
        let placeholder = NibObject("UIImageNibPlaceholder")
        let resource = document.child(named: "resources")?.children(named: "image").first(where: { $0["name"] == name })
        placeholder.add("UIImageWidth", .float(1))
        placeholder.add("UIImageHeight", .float(1))
        if resource?["catalog"] == "system" {
            placeholder.add("UIResourceName", .null)
            placeholder.add("UISystemSymbolResourceName", .object(string(name)))
        } else {
            placeholder.add("UIResourceName", .object(string(name)))
            placeholder.add("UISystemSymbolResourceName", .null)
        }
        placeholder.add("UISymbolImageConfiguration", .null)
        placeholder.add("UIResourceCatalogName", .null)
        valueObjects[key] = placeholder
        return placeholder
    }

    func encodeTableView(_ element: XMLElement2, into object: NibObject) {
        object.add("UIScrollViewIndicatorInsetAdjustmentBehavior", .int(1))
        object.add("UIBouncesZoom", .bool(element.bool("bouncesZoom") ?? true))
        if element.bool("alwaysBounceVertical") == true {
            object.add("UIAlwaysBounceVertical", .bool(true))
        }
        if let dismiss = element["keyboardDismissMode"], let value = UIKitTables.keyboardDismissModes[dismiss], value != 0 {
            object.add("UIKeyboardDismissMode", .ints(value))
        }
        object.add("UIScrollViewContentInsetAdjustmentBehavior", .int(0))
        let style: Int
        switch element["style"] ?? "plain" {
        case "grouped": style = 1
        case "insetGrouped": style = 2
        default: style = 0
        }
        object.add("UITableViewStyle", .ints(style))
        object.add("UIStyle", .ints(style))
        let separator = UIKitTables.tableViewSeparatorStyles[element["separatorStyle"] ?? "default"] ?? 1
        object.add("UISeparatorStyle", .ints(separator))
        object.add("UISeparatorStyleIOS5AndLater", .ints(separator))
        object.add("UIPrefetchingEnabled", .bool(true))
        object.add("UIRowHeight", .float(Float(element.double("rowHeight") ?? 44)))
        object.add("UISectionHeaderHeight", .float(Float(element.double("sectionHeaderHeight") ?? (style == 0 ? 22 : 10))))
        object.add("UISectionFooterHeight", .float(Float(element.double("sectionFooterHeight") ?? (style == 0 ? 22 : 10))))
        object.add("UIEstimatedRowHeight", .float(Float(element.double("estimatedRowHeight") ?? 0)))
        object.add("UIEstimatedSectionHeaderHeight", .float(Float(element.double("estimatedSectionHeaderHeight") ?? 0)))
        object.add("UIEstimatedSectionFooterHeight", .float(Float(element.double("estimatedSectionFooterHeight") ?? 0)))
        object.add("UIFillerRowHeight", .double(0))
        object.add("UISectionHeaderTopPadding", .double(-1))
        object.add("UIInsetsContentViewsToSafeArea", .bool(true))
        let separatorColor = element.child(named: "color", key: "separatorColor").map { color($0) } ?? systemColor("separatorColor")
        object.add("UISeparatorColor", .object(separatorColor))
        object.add("UISeparatorInsetReference", .int(0))
    }

    func encodeTableViewCell(_ element: XMLElement2, frame: Frame, contentView: NibObject?, into object: NibObject) {
        let selection = UIKitTables.tableViewCellSelectionStyles[element["selectionStyle"] ?? "default"] ?? 3
        if selection != 3 {
            object.add("UISelectionStyle", .ints(selection))
        }
        object.add("UIIndentationWidth", .float(Float(element.double("indentationWidth") ?? 10)))

        let background = NibObject("_UISystemBackgroundView")
        background.add("UIBounds", doubles([0, 0, frame.width, frame.height]))
        background.add("UICenter", doubles([frame.width / 2, frame.height / 2]))
        background.add("UIDeepDrawRect", .bool(true))
        background.add("UIOpaque", .bool(true))
        background.add("UIAutoresizeSubviews", .bool(true))
        background.add("UIViewSemanticContentAttribute", .int(0))
        background.add("UIViewLargeContentStoredProperties", .null)
        let configuration = NibObject("UIBackgroundConfiguration")
        configuration.add("customView", .null)
        configuration.add("cornerRadius", .double(0))
        configuration.add("maskedCorners", .int(15))
        configuration.add("backgroundColor", .object(systemColor("tableCellPlainBackgroundColor")))
        configuration.add("backgroundColorTransformerIdentifier", .int(0))
        configuration.add("visualEffect", .null)
        configuration.add("visualEffectGroupName", .null)
        configuration.add("visualEffectblurClippingMode", .int(0))
        configuration.add("image", .null)
        configuration.add("imageContentMode", .int(0))
        configuration.add("backgroundInsets", .object(string("{0, 0, 0, 0}")))
        configuration.add("edgesAddingLayoutMarginsToBackgroundInsets", .int(0))
        configuration.add("strokeColor", .object(systemColor("clearColor")))
        configuration.add("strokeColorTransformerIdentifier", .int(0))
        configuration.add("strokeWidth", .double(0))
        configuration.add("strokeOutset", .double(0))
        configuration.add("strokeLocation", .int(0))
        configuration.add("defaultStyle_v2", .int(11))
        configuration.add("defaultStyle", .int(1))
        for key in ["customView", "cornerRadius", "backgroundInsets", "edgesAddingLayoutMarginsToBackgroundInsets",
                    "backgroundColor", "backgroundColorTransformerIdentifier", "visualEffect", "visualEffectGroupName",
                    "image", "imageContentMode", "strokeColor", "strokeColorTransformerIdentifier", "strokeWidth",
                    "strokeOutset", "maskedCorners"] {
            configuration.add("hasCustomized-\(key)", .bool(false))
        }
        background.add("configurationAPI", .object(configuration))
        object.add("UISystemBackgroundView", .object(background))
        object.add("UIContentConfigurationView", .null)
        if let contentView {
            object.add("UIContentView", .object(contentView))
        }
        object.add("UITextLabel", .null)
        object.add("UIDetailTextLabel", .null)
        object.add("UIImageView", .null)
        if let reuseIdentifier = element["reuseIdentifier"] {
            object.add("UIReuseIdentifier", .object(string(reuseIdentifier)))
        }
    }

    func encodeSearchBar(_ element: XMLElement2, into object: NibObject) {
        object.add("UISearchBarTranslucence", .ints(element.bool("translucent") == false ? 2 : 0))
        object.add("UIText", .object(string(element["text"] ?? "")))
        if let placeholder = element["placeholder"] {
            object.add("UIPlaceholder", .object(localizable(placeholder, element, "placeholder")))
        }
        encodeTextInputTraits(element.child(named: "textInputTraits", key: "textInputTraits"), into: object, forSearchBar: true)
        if let offset = element.child(named: "offsetWrapper", key: "searchTextPositionAdjustment") {
            object.add("UISearchTextPositionAdjustment",
                       .object(string("{\(format(offset.double("horizontal") ?? 0)), \(format(offset.double("vertical") ?? 0))}")))
        }
    }

    // MARK: Layout

    func safeAreaGuide(id: String) -> NibObject {
        if let guide = safeAreaGuides[id] { return guide }
        let guide = NibObject("UILayoutGuide")
        safeAreaGuides[id] = guide
        guard let ownerElement = safeAreaOwners[id], let owner = self.object(for: ownerElement) else {
            warn("safe area layout guide '\(id)' has no owning view")
            return guide
        }
        guide.add("UILayoutGuideOwningView", .object(owner))
        guide.add("UILayoutGuideIdentifier", .object(string("UIViewSafeAreaLayoutGuide")))
        guide.add("UILayoutGuideOwningViewIsLocked", .bool(true))
        guide.add("UILayoutGuideShouldBeArchived", .bool(true))
        guide.add("UILayoutGuideAllowsNegativeDimensions", .bool(true))
        // The guide's own constraints tie it to the owner's edges; UIKit updates their constants with the safe area insets.
        let system: [(NibObject, Int, NibObject, String)] = [
            (guide, 3, owner, "top"), (guide, 1, owner, "left"), (owner, 4, guide, "bottom"), (owner, 2, guide, "right"),
        ]
        let constraints = system.map { first, attribute, second, edge -> NibObject in
            let constraint = NibObject("NSLayoutConstraint")
            constraint.add("NSFirstItem", .object(first))
            constraint.add("NSFirstAttributeV2", .ints(attribute))
            constraint.add("NSFirstAttribute", .ints(attribute))
            constraint.add("NSSecondItem", .object(second))
            constraint.add("NSSecondAttributeV2", .ints(attribute))
            constraint.add("NSSecondAttribute", .ints(attribute))
            constraint.add("NSShouldBeArchived", .bool(false))
            constraint.add("NSLayoutIdentifier", .object(string("UIViewSafeAreaLayoutGuide-\(edge)")))
            return constraint
        }
        guide.add("UILayoutGuideSystemConstraints", .object(array(constraints)))
        return guide
    }

    func constraint(_ element: XMLElement2, owner: XMLElement2, ownerObject: NibObject) -> NibObject? {
        let constraint = NibObject("NSLayoutConstraint")
        if let id = element["id"] { objectsByID[id] = constraint }
        let firstItem = element["firstItem"].flatMap { self.object(id: $0, from: element) } ?? ownerObject
        guard let firstAttributeName = element["firstAttribute"], let firstAttribute = UIKitTables.layoutAttributes[firstAttributeName] else {
            warn("constraint without a known firstAttribute was left out", element)
            return nil
        }
        let constant = element.double("constant") ?? 0
        let symbolic = element.bool("symbolic") == true
        // NSFirstAttribute and NSSecondAttribute keep the pre-iOS 8 meaning: margin attributes become the
        // plain edge, with the default 8 point margin folded into NSConstant. The V2 keys hold the real values.
        var legacyConstant = symbolic ? 0 : constant
        constraint.add("NSFirstItem", .object(firstItem))
        constraint.add("NSFirstAttributeV2", .ints(firstAttribute))
        let (firstLegacy, firstSign) = Self.legacyAttribute(firstAttribute)
        legacyConstant -= firstSign * 8
        constraint.add("NSFirstAttribute", .ints(firstLegacy))
        switch element["relation"] {
        case "lessThanOrEqual": constraint.add("NSRelation", .int(-1))
        case "greaterThanOrEqual": constraint.add("NSRelation", .int(1))
        default: break
        }
        var multiplierValue = 1.0
        if let multiplier = element["multiplier"] {
            let value: Double
            let separator: Character = multiplier.contains("/") ? "/" : ":"
            let parts = multiplier.split(separator: separator)
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 {
                value = a / b
            } else {
                value = Double(multiplier) ?? 1
            }
            multiplierValue = value
            if value != 1 { constraint.add("NSMultiplier", .double(value)) }
        }
        if let secondAttributeName = element["secondAttribute"] {
            guard let secondAttribute = UIKitTables.layoutAttributes[secondAttributeName] else {
                warn("constraint with unknown secondAttribute '\(secondAttributeName)' was left out", element)
                return nil
            }
            let secondItem = element["secondItem"].flatMap { self.object(id: $0, from: element) } ?? ownerObject
            constraint.add("NSSecondItem", .object(secondItem))
            constraint.add("NSSecondAttributeV2", .ints(secondAttribute))
            let (secondLegacy, secondSign) = Self.legacyAttribute(secondAttribute)
            legacyConstant += multiplierValue * secondSign * 8
            constraint.add("NSSecondAttribute", .ints(secondLegacy))
        }
        if symbolic {
            constraint.add("NSSymbolicConstant", .object(string("NSSpace")))
        }
        if constant != 0, !symbolic { constraint.add("NSConstantV2", .double(constant)) }
        constraint.add("NSShouldBeArchived", .bool(true))
        if let priority = element.double("priority"), priority != 1000 {
            constraint.add("NSPriority", .ints(Int(priority)))
        }
        if let identifier = element["identifier"] {
            constraint.add("NSLayoutIdentifier", .object(string(identifier)))
        }
        if legacyConstant != 0 { constraint.add("NSConstant", .double(legacyConstant)) }
        return constraint
    }

    /// The plain attribute for a margin attribute, and the side the margin sits on (+1 inward from a
    /// leading, left or top edge, -1 from a trailing, right or bottom edge).
    static func legacyAttribute(_ attribute: Int) -> (Int, Double) {
        switch attribute {
        case 13: return (1, 1)   // leftMargin
        case 14: return (2, -1)  // rightMargin
        case 15: return (3, 1)   // topMargin
        case 16: return (4, -1)  // bottomMargin
        case 17: return (5, 1)   // leadingMargin
        case 18: return (6, -1)  // trailingMargin
        case 19: return (9, 0)   // centerXWithinMargins
        case 20: return (10, 0)  // centerYWithinMargins
        default: return (attribute, 0)
        }
    }

    // MARK: Size class variations

    /// `<variation>` masks become trait storage that UIKit applies when the trait collection changes.
    func traitStorageList(_ top: XMLElement2) -> NibObject? {
        guard let topObject = top["id"].flatMap({ objectsByID[$0] }) else { return nil }
        var storages: [NibObject] = []
        var descendants: [NibObject] = []
        func walk(_ element: XMLElement2, isTop: Bool) {
            if !isTop, let object = element["id"].flatMap({ objectsByID[$0] }), element.name != "constraint" {
                descendants.append(object)
            }
            let variations = element.children(named: "variation")
            if !variations.isEmpty, let object = element["id"].flatMap({ objectsByID[$0] }) {
                storages.append(constraintTraitStorage(element, owner: object, variations: variations))
            }
            for child in element.child(named: "subviews")?.children ?? [] { walk(child, isTop: false) }
            if let content = element.child(named: "tableViewCellContentView", key: "contentView") { walk(content, isTop: false) }
        }
        walk(top, isTop: true)
        guard !storages.isEmpty else { return nil }
        let list = NibObject("_UITraitStorageList")
        list.add("UITopLevelObject", .object(topObject))
        list.add("UITraitStorages", .object(array(storages)))
        list.add("UIDescendants", .object(set(descendants)))
        return list
    }

    func constraintTraitStorage(_ element: XMLElement2, owner: NibObject, variations: [XMLElement2]) -> NibObject {
        let storage = NibObject("_UIRelationshipTraitStorage")
        storage.add("UIObject", .object(owner))
        storage.add("UIKeyPath", .object(string("traitStorageConstraints")))
        var records: [NibObject] = []
        for variation in variations {
            guard let mask = variation.children(named: "mask").first(where: { $0["key"] == "constraints" }) else {
                warn("size class variation without a constraints mask was ignored", variation)
                continue
            }
            let record = NibObject("_UIRelationshipTraitStorageRecord")
            let traits = NibObject("UITraitCollection")
            for part in (variation["key"] ?? "default").split(separator: "-") {
                let pair = part.split(separator: "=").map(String.init)
                guard pair.count == 2 else { continue }
                let value = pair[1] == "compact" ? 1 : pair[1] == "regular" ? 2 : 0
                if pair[0] == "widthClass" {
                    traits.add("UITraitCollectionBuiltinTrait-_UITraitNameHorizontalSizeClass", .ints(value))
                } else if pair[0] == "heightClass" {
                    traits.add("UITraitCollectionBuiltinTrait-_UITraitNameVerticalSizeClass", .ints(value))
                }
            }
            // ibtool writes the horizontal class before the vertical one.
            traits.values.sort { $0.key.contains("Horizontal") && !$1.key.contains("Horizontal") }
            record.add("UITraitCollection", .object(traits))
            let included = mask.children(named: "include").compactMap { $0["reference"].flatMap { objectsByID[$0] } }
            let excluded = mask.children(named: "exclude").compactMap { $0["reference"].flatMap { objectsByID[$0] } }
            record.add("UIAddedObjects", .object(set(included)))
            record.add("UIRemovedObjects", .object(set(excluded)))
            records.append(record)
        }
        storage.add("UIRecords", .object(array(records, mutable: true)))
        let candidates = NibObject("NSOrderedSet")
        let constraints = element.child(named: "constraints")?.children(named: "constraint")
            .compactMap { $0["id"].flatMap { objectsByID[$0] } } ?? []
        for (i, constraint) in constraints.enumerated() { candidates.add("NS.object.\(i)", .object(constraint)) }
        storage.add("UIRelationshipCandidates", .object(candidates))
        return storage
    }

    func set(_ items: [NibObject]) -> NibObject {
        let object = NibObject("NSSet")
        for (i, item) in items.enumerated() { object.add("NS.object.\(i)", .object(item)) }
        return object
    }

    // MARK: Objects list and connections

    func collectAllObjects(_ element: XMLElement2) {
        guard let object = element["id"].flatMap({ objectsByID[$0] }) else { return }
        allObjects.append(object)
        var queue: [XMLElement2] = [element]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            var children: [XMLElement2] = []
            if let guide = current.child(named: "viewLayoutGuide", key: "safeArea") { children.append(guide) }
            children += current.child(named: "constraints")?.children(named: "constraint") ?? []
            if let content = current.child(named: "tableViewCellContentView", key: "contentView") { children.append(content) }
            children += current.child(named: "subviews")?.children ?? []
            for child in children {
                if child.name == "viewLayoutGuide" {
                    // The xib's guide object is archived on its own; UIKit replaces it with the owner's guide.
                    let placeholder = NibObject("UILayoutGuide")
                    placeholder.add("UILayoutGuideOwningView", .null)
                    placeholder.add("UILayoutGuideIdentifier", .object(string("")))
                    placeholder.add("UILayoutGuideOwningViewIsLocked", .bool(false))
                    placeholder.add("UILayoutGuideShouldBeArchived", .bool(false))
                    placeholder.add("UILayoutGuideAllowsNegativeDimensions", .bool(false))
                    allObjects.append(placeholder)
                    continue
                }
                if let object = child["id"].flatMap({ objectsByID[$0] }) {
                    allObjects.append(object)
                }
                if child.name != "constraint" { queue.append(child) }
            }
        }
    }

    func collectConnections(_ element: XMLElement2) {
        if let connections = element.child(named: "connections"), let source = element["id"].flatMap({ objectsByID[$0] }) {
            for connection in connections.children {
                guard let destinationID = connection["destination"], let destination = self.object(id: destinationID, from: connection) else {
                    continue
                }
                switch connection.name {
                case "outlet":
                    guard let property = connection["property"] else { continue }
                    outlets.append((property, source, destination, outlets.count))
                case "outletCollection":
                    guard let property = connection["property"] else { continue }
                    if let index = collections.firstIndex(where: { $0.label == property && $0.source === source }) {
                        collections[index].destinations.append(destination)
                    } else {
                        collections.append((property, source, [destination], connection.bool("appends") ?? false,
                                            connection["collectionClass"] ?? "NSArray"))
                    }
                case "action":
                    guard let selector = connection["selector"] else { continue }
                    var mask: Int?
                    if let eventType = connection["eventType"] {
                        guard let value = UIKitTables.controlEvents[eventType] else {
                            warn("unknown control event '\(eventType)'", connection)
                            continue
                        }
                        mask = value
                    }
                    // Actions on controls target the destination; the source sends them.
                    events.append((selector, source, destination, mask, events.count))
                case "segue":
                    warn("segues are not supported in xibs", connection)
                default:
                    warn("unsupported connection <\(connection.name)>", connection)
                }
            }
        }
        for child in element.children where child.name != "connections" {
            collectConnections(child)
        }
    }

    func connectionObjects() -> [NibObject] {
        var result: [NibObject] = []
        for collection in collections {
            let connection = NibObject("UIRuntimeOutletCollectionConnection")
            connection.add("UILabel", .object(string(collection.label)))
            connection.add("UISource", .object(collection.source))
            let destinations = NibObject("NSMutableArray")
            destinations.add("NSInlinedValue", .bool(true))
            for destination in collection.destinations { destinations.add("UINibEncoderEmptyKey", .object(destination)) }
            connection.add("UIDestination", .object(destinations))
            connection.add("runtimeCollectionClassName", .object(string(collection.className)))
            connection.add("addsContentToExistingCollection", .bool(collection.appends))
            result.append(connection)
        }
        // ibtool orders outlets by property name; equal names keep the reverse of document order.
        let sortedOutlets = outlets.sorted { a, b in
            a.label != b.label ? a.label < b.label : a.order > b.order
        }
        for outlet in sortedOutlets {
            let connection = NibObject("UIRuntimeOutletConnection")
            connection.add("UILabel", .object(string(outlet.label)))
            connection.add("UISource", .object(outlet.source))
            connection.add("UIDestination", .object(outlet.destination))
            result.append(connection)
        }
        // Gesture recognizer targets (no event mask) come first, then control actions by event and selector.
        let sortedEvents = events.sorted { a, b in
            let maskA = a.mask ?? 0, maskB = b.mask ?? 0
            if maskA != maskB { return maskA < maskB }
            if a.label != b.label { return a.label < b.label }
            return a.order < b.order
        }
        for event in sortedEvents {
            let connection = NibObject("UIRuntimeEventConnection")
            connection.add("UILabel", .object(string(event.label)))
            connection.add("UISource", .object(event.source))
            connection.add("UIDestination", .object(event.destination))
            if let mask = event.mask { connection.add("UIEventMask", .ints(mask)) }
            result.append(connection)
        }
        return result
    }

    func encodeUserDefinedRuntimeAttributes(_ element: XMLElement2, object: NibObject) {
        guard let attributes = element.child(named: "userDefinedRuntimeAttributes") else { return }
        for attribute in attributes.children(named: "userDefinedRuntimeAttribute") {
            guard let keyPath = attribute["keyPath"] else { continue }
            let value: NibObject
            switch attribute["type"] ?? "" {
            case "color":
                guard let colorElement = attribute.child(named: "color", key: "value") else { continue }
                value = color(colorElement)
            case "string", "localizedString", "image":
                value = string(attribute["value"] ?? "")
            case "boolean":
                value = number(attribute["value"] == "YES" ? 1 : 0)
            case "number":
                let raw = attribute.child(named: "integer", key: "value")?["value"]
                    ?? attribute.child(named: "real", key: "value")?["value"] ?? attribute["value"] ?? "0"
                if let int = Int(raw) { value = number(int) } else { value = number(double: Double(raw) ?? 0) }
            case "point":
                let point = attribute.child(named: "point", key: "value")
                value = nsValue(special: 1, key: "NS.pointval",
                                string: "{\(format(point?.double("x") ?? 0)), \(format(point?.double("y") ?? 0))}")
            case "size":
                let size = attribute.child(named: "size", key: "value")
                value = nsValue(special: 2, key: "NS.sizeval",
                                string: "{\(format(size?.double("width") ?? 0)), \(format(size?.double("height") ?? 0))}")
            case "rect":
                let rect = attribute.child(named: "rect", key: "value")
                value = rectValue(Frame(x: rect?.double("x") ?? 0, y: rect?.double("y") ?? 0,
                                        width: rect?.double("width") ?? 0, height: rect?.double("height") ?? 0))
            case "nil":
                warn("nil user-defined runtime attribute '\(keyPath)' was left out", attribute)
                continue
            default:
                warn("unsupported user-defined runtime attribute type '\(attribute["type"] ?? "")'", attribute)
                continue
            }
            keyValuePairs.append(keyValuePair(object: object, keyPath: keyPath, value: value))
        }
    }

    func keyValuePair(object: NibObject, keyPath: String, value: NibObject) -> NibObject {
        let pair = NibObject("UINibKeyValuePair")
        pair.add("UIObject", .object(object))
        pair.add("UIValue", .object(value))
        pair.add("UIKeyPath", .object(string(keyPath)))
        return pair
    }

    func rectValue(_ frame: Frame) -> NibObject {
        nsValue(special: 3, key: "NS.rectval",
                string: "{{\(format(frame.x)), \(format(frame.y))}, {\(format(frame.width)), \(format(frame.height))}}")
    }

    func nsValue(special: Int, key: String, string value: String) -> NibObject {
        let object = NibObject("NSValue")
        object.add("NS.special", .ints(special))
        object.add(key, .object(string(value)))
        return object
    }

    // MARK: Attribute coverage

    static let handledViewAttributes: Set<String> = [
        "id", "customClass", "customModule", "customModuleProvider", "userLabel", "contentMode", "opaque",
        "clipsSubviews", "multipleTouchEnabled", "userInteractionEnabled", "translatesAutoresizingMaskIntoConstraints",
        "horizontalHuggingPriority", "verticalHuggingPriority", "horizontalCompressionResistancePriority",
        "verticalCompressionResistancePriority", "tag", "hidden", "alpha", "clearsContextBeforeDrawing",
        "autoresizesSubviews", "key", "ambiguous", "misplaced", "fixedFrame", "insetsLayoutMarginsFromSafeArea",
        "preservesSuperviewLayoutMargins",
        // UILabel
        "text", "textAlignment", "lineBreakMode", "numberOfLines", "baselineAdjustment", "adjustsFontSizeToFit",
        "minimumFontSize", "minimumScaleFactor", "adjustsLetterSpacingToFitWidth", "preferredMaxLayoutWidth",
        // UIControl and UIButton
        "contentHorizontalAlignment", "contentVerticalAlignment", "buttonType", "selected", "enabled", "highlighted",
        "adjustsImageWhenHighlighted", "adjustsImageWhenDisabled", "pointerInteraction", "showsTouchWhenHighlighted",
        // UITextField
        "borderStyle", "placeholder", "clearButtonMode", "clearsOnBeginEditing",
        // UISwitch, UISlider, UIStepper
        "on", "value", "minValue", "maxValue", "continuous", "minimumValue", "maximumValue", "stepValue",
        "autorepeat", "wraps",
        // UIImageView
        "image", "highlightedImage",
        // UIScrollView and UITableView
        "alwaysBounceVertical", "alwaysBounceHorizontal", "bouncesZoom", "keyboardDismissMode", "style",
        "separatorStyle", "rowHeight", "sectionHeaderHeight", "sectionFooterHeight", "estimatedRowHeight",
        "estimatedSectionHeaderHeight", "estimatedSectionFooterHeight", "showsHorizontalScrollIndicator",
        "showsVerticalScrollIndicator", "dataMode",
        // UITableViewCell
        "selectionStyle", "indentationWidth", "reuseIdentifier", "tableViewCell", "accessoryType", "indentationLevel",
        // UISearchBar
        "translucent",
        // Gesture recognizers
        "numberOfTapsRequired", "numberOfTouchesRequired", "cancelsTouchesInView", "delaysTouchesBegan",
        "delaysTouchesEnded",
    ]

    func checkAttributes(_ element: XMLElement2) {
        for attribute in element.attributes.keys where !Self.handledViewAttributes.contains(attribute) {
            warn("attribute '\(attribute)' of <\(element.name)> is not supported and was ignored", element)
        }
    }

    // MARK: Values

    func localizable(_ value: String, _ element: XMLElement2, _ property: String) -> NibObject {
        guard options.localizable, let id = element["id"] else { return string(value) }
        let object = NibObject("NSLocalizableString")
        object.add("NS.bytes", .data(Array(value.utf8)))
        object.add("NSKey", .object(string("\(id).\(property)")))
        object.add("NSDev", .object(string(value)))
        return object
    }

    func string(_ value: String) -> NibObject {
        let key = "NSString|" + value
        if let existing = valueObjects[key] { return existing }
        let object = NibObject("NSString")
        object.add("NS.bytes", .data(Array(value.utf8)))
        valueObjects[key] = object
        return object
    }

    func number(_ value: Int) -> NibObject {
        let key = "NSNumber|i\(value)"
        if let existing = valueObjects[key] { return existing }
        let object = NibObject("NSNumber")
        object.add("NS.intval", .ints(value))
        valueObjects[key] = object
        return object
    }

    func number(double value: Double) -> NibObject {
        let key = "NSNumber|d\(value)"
        if let existing = valueObjects[key] { return existing }
        let object = NibObject("NSNumber")
        object.add("NS.dblval", .double(value))
        valueObjects[key] = object
        return object
    }

    /// NSArray archive; equal arrays (same elements) are archived once, as UINibEncoder uniques equal objects.
    func array(_ items: [NibObject], mutable: Bool = false) -> NibObject {
        let key = "NSArray|" + items.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ",")
        if let existing = valueObjects[key] { return existing }
        let object = NibObject(mutable ? "NSMutableArray" : "NSArray")
        object.add("NSInlinedValue", .bool(true))
        for item in items { object.add("UINibEncoderEmptyKey", .object(item)) }
        valueObjects[key] = object
        return object
    }

    func doubles(_ values: [Double]) -> NibValue {
        var bytes: [UInt8] = [0x07]
        for value in values { NibArchive.appendLE(value.bitPattern, to: &bytes) }
        return .data(bytes)
    }

    func color(_ element: XMLElement2) -> NibObject {
        if let name = element["systemColor"] ?? element["cocoaTouchSystemColor"] {
            return systemColor(name)
        }
        if let white = element.double("white") {
            let alpha = element.double("alpha") ?? 1
            let space = element["customColorSpace"] ?? element["colorSpace"] ?? ""
            if space.contains("calibratedWhite") || space == "deviceWhite" {
                // Calibrated and device gray end up as sRGB colors.
                return colorObject(systemName: nil, value: .rgb(white, white, white, alpha: alpha))
            }
            // Interface Builder hands out UIKit's named black and white colors for exact matches.
            if alpha == 1 && white == 0 { return systemColor("blackColor") }
            if alpha == 1 && white == 1 { return systemColor("whiteColor") }
            if alpha == 0 && white == 0 { return systemColor("clearColor") }
            return colorObject(systemName: nil, value: .white(white, alpha: alpha))
        }
        if let red = element.double("red") {
            return colorObject(systemName: nil, value: .rgb(red, element.double("green") ?? 0, element.double("blue") ?? 0,
                                                            alpha: element.double("alpha") ?? 1))
        }
        warn("unsupported color; archived as clear", element)
        return colorObject(systemName: nil, value: .white(0, alpha: 0))
    }

    func systemColor(_ name: String) -> NibObject {
        let value: UIKitTables.ColorValue
        if let resource = resourceColors[name] {
            if let white = resource.double("white") {
                value = .white(white, alpha: resource.double("alpha") ?? 1)
            } else {
                value = .rgb(resource.double("red") ?? 0, resource.double("green") ?? 0, resource.double("blue") ?? 0,
                             alpha: resource.double("alpha") ?? 1)
            }
        } else if let known = UIKitTables.systemColors[name] {
            value = known
        } else {
            warn("unknown system color '\(name)'; archived as black")
            value = .white(0, alpha: 1)
        }
        return colorObject(systemName: name, value: value)
    }

    func colorObject(systemName: String?, value: UIKitTables.ColorValue) -> NibObject {
        // UINibEncoder archives equal objects once. Fixed colors (custom ones and UIKit's black, white,
        // clear, darkText...) compare by value, so the first one archived stands in for the rest;
        // dynamic system colors only equal themselves.
        let isFixed = systemName.map { UIKitTables.fixedSystemColors.contains($0) } ?? true
        let key = isFixed ? "UIColor|fixed|\(value)" : "UIColor|\(systemName!)|\(value)"
        if let existing = valueObjects[key] { return existing }
        let object = NibObject("UIColor", fallbacks: ["NSColor"])
        if let systemName {
            object.add("UISystemColorName", .object(string(systemName)))
        }
        func component(_ name: String, _ v: Double) {
            object.add(name, .float(Float(v)))
            if Double(Float(v)) != v {
                object.add("\(name)-Double", .double(v))
            }
        }
        switch value {
        case .white(let white, let alpha):
            object.add("UIColorComponentCount", .int(2))
            component("UIWhite", white)
            component("UIAlpha", alpha)
            object.add("NSWhite", .data(Array(componentString([white], alpha: alpha).utf8)))
            object.add("NSColorSpace", .int(4))
        case .rgb(let red, let green, let blue, let alpha):
            object.add("UIColorComponentCount", .int(4))
            component("UIRed", red)
            component("UIGreen", green)
            component("UIBlue", blue)
            component("UIAlpha", alpha)
            object.add("NSRGB", .data(Array(componentString([red, green, blue], alpha: alpha).utf8)))
            object.add("NSColorSpace", .int(2))
        }
        valueObjects[key] = object
        return object
    }

    func componentString(_ components: [Double], alpha: Double) -> String {
        var parts = components
        if alpha != 1 { parts.append(alpha) }
        return parts.map { String(format: "%.3g", $0) }.joined(separator: " ")
    }

    func font(_ description: XMLElement2?, defaultSize: Double) -> NibObject {
        let type = description?["type"] ?? (description?["name"] == nil && description?["style"] == nil ? "system" : nil)
        if let style = description?["style"] {
            let known = UIKitTables.textStyles[style] ?? (".SFUI-Regular", 0, 14)
            let key = "UIFont|style|\(style)"
            if let existing = valueObjects[key] { return existing }
            let font = NibObject("UIFont", fallbacks: ["NSFont"])
            let name = string(known.name)
            font.add("UIFontName", .object(name))
            font.add("UIIBTextStyle", .object(string(style)))
            font.add("UIFontPointSize", .double(0))
            font.add("UIFontTextStyleForScaling", .null)
            font.add("UIFontPointSizeForScaling", .double(0))
            font.add("UIFontMaximumPointSizeAfterScaling", .double(0))
            font.add("UIFontTraits", .ints(known.traits))
            font.add("UISystemFont", .bool(true))
            font.add("NSName", .object(name))
            font.add("NSSize", .double(known.size))
            valueObjects[key] = font
            return font
        }
        let size = description?.double("pointSize") ?? defaultSize
        if let type {
            let system = UIKitTables.systemFont(type: type, weight: description?["weight"])
            let key = "UIFont|system|\(system.name)|\(system.usage)|\(size)"
            if let existing = valueObjects[key] { return existing }
            let font = NibObject("UIFont", fallbacks: ["NSFont"])
            let name = string(system.name)
            font.add("UIFontName", .object(name))
            let descriptor = NibObject("UIFontDescriptor")
            let attributes = NibObject(system.usageOverride == nil ? "NSDictionary" : "NSMutableDictionary")
            attributes.add("NSInlinedValue", .bool(true))
            attributes.add("UINibEncoderEmptyKey", .object(string("NSCTFontUIUsageAttribute")))
            attributes.add("UINibEncoderEmptyKey", .object(string(system.usage)))
            if let usageOverride = system.usageOverride {
                attributes.add("UINibEncoderEmptyKey", .object(string("NSCTFontUIUsageOverrideAttribute")))
                attributes.add("UINibEncoderEmptyKey", .object(string(usageOverride)))
            }
            attributes.add("UINibEncoderEmptyKey", .object(string("NSFontSizeAttribute")))
            attributes.add("UINibEncoderEmptyKey", .object(number(double: size)))
            descriptor.add("UIFontDescriptorAttributes", .object(attributes))
            descriptor.add("UIFontDescriptorOptions", .int(2147517444))
            font.add("UIFontDescriptor", .object(descriptor))
            font.add("UIFontPointSize", .double(size))
            font.add("UIFontTextStyleForScaling", .null)
            font.add("UIFontPointSizeForScaling", .double(0))
            font.add("UIFontMaximumPointSizeAfterScaling", .double(0))
            font.add("UIFontTraits", .ints(system.traits))
            font.add("UISystemFont", .bool(true))
            font.add("NSName", .object(name))
            font.add("NSSize", .double(size))
            valueObjects[key] = font
            return font
        }
        let fontName = description?["name"] ?? "Helvetica"
        let key = "UIFont|named|\(fontName)|\(size)"
        if let existing = valueObjects[key] { return existing }
        let isCustom = customFontNames.contains(fontName)
        let font = NibObject("UIFont", fallbacks: ["NSFont"])
        let name = string(fontName)
        font.add("UIFontName", .object(name))
        let descriptor = NibObject("UIFontDescriptor")
        let attributes = NibObject("NSDictionary")
        attributes.add("NSInlinedValue", .bool(true))
        attributes.add("UINibEncoderEmptyKey", .object(string("NSFontNameAttribute")))
        attributes.add("UINibEncoderEmptyKey", .object(name))
        attributes.add("UINibEncoderEmptyKey", .object(string("NSFontSizeAttribute")))
        attributes.add("UINibEncoderEmptyKey", .object(number(double: size)))
        descriptor.add("UIFontDescriptorAttributes", .object(attributes))
        // App fonts are not registered when ibtool runs, so they archive like a font UIKit cannot load yet.
        descriptor.add("UIFontDescriptorOptions", .int(isCustom ? 0 : 2147483648))
        font.add("UIFontDescriptor", .object(descriptor))
        font.add("UIFontPointSize", .double(size))
        if !isCustom {
            font.add("UIFontTextStyleForScaling", .null)
            font.add("UIFontPointSizeForScaling", .double(0))
            font.add("UIFontMaximumPointSizeAfterScaling", .double(0))
        }
        font.add("UIFontTraits", .int(0))
        font.add("UISystemFont", .bool(false))
        font.add("NSName", .object(name))
        font.add("NSSize", .double(size))
        valueObjects[key] = font
        return font
    }

    /// Formats a number the way NSStringFromCGRect does: integers without a fraction, others with up to 17 digits.
    func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.17g", value)
    }
}
