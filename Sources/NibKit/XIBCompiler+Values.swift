import Foundation

extension XIBCompiler {
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
