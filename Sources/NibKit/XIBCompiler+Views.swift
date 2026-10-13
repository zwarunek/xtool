import Foundation

extension XIBCompiler {
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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        let inset: Double = 8
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

    // swiftlint:disable:next cyclomatic_complexity
    func encodeButton(_ element: XMLElement2, into object: NibObject) {
        if let horizontal = element["contentHorizontalAlignment"],
           let value = UIKitTables.contentHorizontalAlignments[horizontal], value != 0 {
            object.add("UIContentHorizontalAlignment", .ints(value))
        }
        if let vertical = element["contentVerticalAlignment"],
           let value = UIKitTables.contentVerticalAlignments[vertical], value != 0 {
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
        if let vertical = element["contentVerticalAlignment"],
           let value = UIKitTables.contentVerticalAlignments[vertical], value != 0 {
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

    // swiftlint:disable:next cyclomatic_complexity
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
        for (attribute, key, defaultValue) in [("value", "UIValue", Double(0)), ("minimumValue", "UIMinimumValue", 0),
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
}
