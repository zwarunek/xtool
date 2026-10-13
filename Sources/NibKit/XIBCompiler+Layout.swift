import Foundation

extension XIBCompiler {
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

    // swiftlint:disable:next cyclomatic_complexity
    func constraint(_ element: XMLElement2, owner: XMLElement2, ownerObject: NibObject) -> NibObject? {
        let constraint = NibObject("NSLayoutConstraint")
        if let id = element["id"] { objectsByID[id] = constraint }
        let firstItem = element["firstItem"].flatMap { self.object(id: $0, from: element) } ?? ownerObject
        guard let firstAttributeName = element["firstAttribute"],
              let firstAttribute = UIKitTables.layoutAttributes[firstAttributeName] else {
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
        var multiplierValue: Double = 1
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

    // swiftlint:disable:next cyclomatic_complexity
    func collectConnections(_ element: XMLElement2) {
        if let connections = element.child(named: "connections"), let source = element["id"].flatMap({ objectsByID[$0] }) {
            for connection in connections.children {
                guard let destinationID = connection["destination"],
                      let destination = self.object(id: destinationID, from: connection) else {
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

    // swiftlint:disable:next cyclomatic_complexity
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
}
