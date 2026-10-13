import Foundation

/// Values that ibtool takes from the live UIKit of the iOS 26 SDK rather than from the xib.
/// They were read from nibs that Xcode 26.5's ibtool produced; see Tests/NibKitTests/Fixtures.
enum UIKitTables {
    enum ColorValue {
        case white(Double, alpha: Double)
        case rgb(Double, Double, Double, alpha: Double)
    }

    /// Light-appearance values of system colors, used when the xib names a system color without a
    /// `<resources>` entry (the UIKit default colors) or for class defaults.
    static let systemColors: [String: ColorValue] = [
        "labelColor": .white(0, alpha: 1),
        "darkTextColor": .white(0, alpha: 1),
        "lightTextColor": .white(1, alpha: 0.6),
        "clearColor": .white(0, alpha: 0),
        "blackColor": .white(0, alpha: 1),
        "whiteColor": .white(1, alpha: 1),
        "systemBackgroundColor": .white(1, alpha: 1),
        "tableCellPlainBackgroundColor": .white(1, alpha: 1),
        "tableCellGroupedBackgroundColor": .white(1, alpha: 1),
        "secondarySystemBackgroundColor": .rgb(0.94901960784313721, 0.94901960784313721, 0.96862745098039216, alpha: 1),
        "groupTableViewBackgroundColor": .rgb(0.94901960784313721, 0.94901960784313721, 0.96862745098039216, alpha: 1),
        "systemGroupedBackgroundColor": .rgb(0.94901960784313721, 0.94901960784313721, 0.96862745098039216, alpha: 1),
        "separatorColor": .rgb(0.23529411764705882, 0.23529411764705882, 0.2627450980392157, alpha: 0.12),
        "secondaryLabelColor": .rgb(0.23529411764705882, 0.23529411764705882, 0.2627450980392157, alpha: 0.6),
        "tertiaryLabelColor": .rgb(0.23529411764705882, 0.23529411764705882, 0.2627450980392157, alpha: 0.3),
        "systemBlueColor": .rgb(0, 0.53333333333333333, 1, alpha: 1),
        "systemRedColor": .rgb(1, 0.2196078431372549, 0.23529411764705882, alpha: 1),
        "systemGrayColor": .rgb(0.55686274509803924, 0.55686274509803924, 0.57647058823529407, alpha: 1),
    ]

    /// System colors that are plain fixed colors rather than dynamic (appearance-dependent) ones.
    static let fixedSystemColors: Set<String> = [
        "blackColor", "whiteColor", "clearColor", "darkTextColor", "lightTextColor", "grayColor",
        "lightGrayColor", "darkGrayColor", "redColor", "greenColor", "blueColor", "cyanColor", "yellowColor",
        "magentaColor", "orangeColor", "purpleColor", "brownColor",
    ]

    struct SystemFont {
        let name: String
        let usage: String
        let usageOverride: String?
        let traits: Int
    }

    /// `type=` and `weight=` of a `<fontDescription>` for the system font.
    static func systemFont(type: String, weight: String?) -> SystemFont {
        switch (type, weight ?? "") {
        case ("boldSystem", _):
            return SystemFont(name: ".SFUI-Bold", usage: "CTFontEmphasizedUsage", usageOverride: "CTFontBoldUsage", traits: 2)
        case ("italicSystem", _):
            return SystemFont(name: ".SFUI-RegularItalic", usage: "CTFontObliqueUsage", usageOverride: nil, traits: 1)
        case (_, "ultraLight"): return SystemFont(name: ".SFUI-Ultralight", usage: "CTFontUltraLightUsage", usageOverride: nil, traits: 0)
        case (_, "thin"): return SystemFont(name: ".SFUI-Thin", usage: "CTFontThinUsage", usageOverride: nil, traits: 0)
        case (_, "light"): return SystemFont(name: ".SFUI-Light", usage: "CTFontLightUsage", usageOverride: nil, traits: 0)
        case (_, "medium"): return SystemFont(name: ".SFUI-Medium", usage: "CTFontMediumUsage", usageOverride: nil, traits: 0)
        case (_, "semibold"): return SystemFont(name: ".SFUI-Semibold", usage: "CTFontDemiUsage", usageOverride: nil, traits: 2)
        case (_, "bold"): return SystemFont(name: ".SFUI-Bold", usage: "CTFontBoldUsage", usageOverride: nil, traits: 2)
        case (_, "heavy"): return SystemFont(name: ".SFUI-Heavy", usage: "CTFontHeavyUsage", usageOverride: nil, traits: 2)
        case (_, "black"): return SystemFont(name: ".SFUI-Black", usage: "CTFontBlackUsage", usageOverride: nil, traits: 2)
        default: return SystemFont(name: ".SFUI-Regular", usage: "CTFontRegularUsage", usageOverride: nil, traits: 0)
        }
    }

    /// Dynamic Type styles as ibtool archives them: font name, symbolic traits and the archived size.
    /// UIKit resolves these again at load time from `UIIBTextStyle`.
    static let textStyles: [String: (name: String, traits: Int, size: Double)] = [
        "UICTFontTextStyleHeadline": (".SFUI-Semibold", 2, 14),
        "UICTFontTextStyleBody": (".SFUI-Regular", 0, 14),
        "UICTFontTextStyleCallout": (".SFUI-Regular", 0, 13),
        "UICTFontTextStyleSubhead": (".SFUI-Regular", 0, 12),
        "UICTFontTextStyleFootnote": (".SFUI-Regular", 0, 12),
        "UICTFontTextStyleCaption1": (".SFUI-Regular", 0, 11),
        "UICTFontTextStyleCaption2": (".SFUI-Regular", 0, 11),
        "UICTFontTextStyleTitle1": (".SFUI-Regular", 0, 25),
        "UICTFontTextStyleTitle2": (".SFUI-Regular", 0, 19),
        "UICTFontTextStyleTitle3": (".SFUI-Regular", 0, 17),
        "UICTFontTextStyleLargeTitle": (".SFUI-Regular", 0, 31),
    ]

    /// UISwitch has a fixed size; ibtool archives that size and restores the xib frame with a key-value pair.
    static let switchSize = (width: 63.0, height: 28.0)

    /// Content hugging priorities that UIKit classes start with. ibtool archives
    /// `UIViewContentHuggingPriority` whenever the xib's value differs from these.
    static func defaultHugging(_ uikitClass: String) -> (Double, Double) {
        switch uikitClass {
        case "UISwitch", "UIStepper", "UIActivityIndicatorView", "UIPageControl", "UISegmentedControl":
            return (750, 750)
        case "UISlider", "UISearchBar", "UIProgressView":
            // These report no default; ibtool always archives the xib's priorities.
            return (-1, -1)
        default:
            return (250, 250)
        }
    }

    static func defaultCompressionResistance(_ uikitClass: String) -> (Double, Double) {
        (750, 750)
    }

    static let layoutAttributes: [String: Int] = [
        "left": 1, "right": 2, "top": 3, "bottom": 4, "leading": 5, "trailing": 6,
        "width": 7, "height": 8, "centerX": 9, "centerY": 10, "lastBaseline": 11, "baseline": 11,
        "firstBaseline": 12, "leftMargin": 13, "rightMargin": 14, "topMargin": 15, "bottomMargin": 16,
        "leadingMargin": 17, "trailingMargin": 18, "centerXWithinMargins": 19, "centerYWithinMargins": 20,
    ]

    static let contentModes: [String: Int] = [
        "scaleToFill": 0, "scaleAspectFit": 1, "scaleAspectFill": 2, "redraw": 3, "center": 4,
        "top": 5, "bottom": 6, "left": 7, "right": 8, "topLeft": 9, "topRight": 10,
        "bottomLeft": 11, "bottomRight": 12,
    ]

    static let controlEvents: [String: Int] = [
        "touchDown": 1 << 0, "touchDownRepeat": 1 << 1, "touchDragInside": 1 << 2,
        "touchDragOutside": 1 << 3, "touchDragEnter": 1 << 4, "touchDragExit": 1 << 5,
        "touchUpInside": 1 << 6, "touchUpOutside": 1 << 7, "touchCancel": 1 << 8,
        "valueChanged": 1 << 12, "primaryActionTriggered": 1 << 13, "menuActionTriggered": 1 << 14,
        "editingDidBegin": 1 << 16, "editingChanged": 1 << 17, "editingDidEnd": 1 << 18,
        "editingDidEndOnExit": 1 << 19,
    ]

    static let controlStates: [String: Int] = [
        "normal": 0, "highlighted": 1, "disabled": 2, "selected": 4, "focused": 8,
    ]

    static let lineBreakModes: [String: Int] = [
        "wordWrap": 0, "characterWrap": 1, "clip": 2, "headTruncation": 3,
        "tailTruncation": 4, "middleTruncation": 5,
    ]

    static let textAlignments: [String: Int] = [
        "left": 0, "center": 1, "right": 2, "justified": 3, "natural": 4,
    ]

    static let buttonTypes: [String: Int] = [
        "custom": 0, "system": 1, "roundedRect": 1, "detailDisclosure": 2, "infoLight": 3,
        "infoDark": 4, "contactAdd": 5, "close": 7,
    ]

    static let keyboardTypes: [String: Int] = [
        "default": 0, "alphabet": 1, "asciiCapable": 1, "numbersAndPunctuation": 2, "URL": 3,
        "numberPad": 4, "phonePad": 5, "namePhonePad": 6, "emailAddress": 7, "decimalPad": 8,
        "twitter": 9, "webSearch": 10, "asciiCapableNumberPad": 11,
    ]

    static let returnKeyTypes: [String: Int] = [
        "default": 0, "go": 1, "google": 2, "join": 3, "next": 4, "route": 5, "search": 6,
        "send": 7, "yahoo": 8, "done": 9, "emergencyCall": 10, "continue": 11,
    ]

    /// UITextAutocorrectionType, UITextSpellCheckingType and the smart-* traits share this mapping.
    static let traitTriState: [String: Int] = ["default": 0, "no": 1, "yes": 2]

    static let autocapitalizationTypes: [String: Int] = [
        "none": 0, "words": 1, "sentences": 2, "allCharacters": 3,
    ]

    static let borderStyles: [String: Int] = ["none": 0, "line": 1, "bezel": 2, "roundedRect": 3]

    static let clearButtonModes: [String: Int] = ["never": 0, "whileEditing": 1, "unlessEditing": 2, "always": 3]

    static let contentHorizontalAlignments: [String: Int] = [
        "center": 0, "left": 1, "right": 2, "fill": 3, "leading": 4, "trailing": 5,
    ]

    static let contentVerticalAlignments: [String: Int] = ["center": 0, "top": 1, "bottom": 2, "fill": 3]

    static let tableViewCellSelectionStyles: [String: Int] = ["none": 0, "blue": 1, "gray": 2, "default": 3]

    static let tableViewSeparatorStyles: [String: Int] = ["none": 0, "default": 1, "singleLine": 1, "singleLineEtched": 2]

    static let keyboardDismissModes: [String: Int] = ["none": 0, "onDrag": 1, "interactive": 2]
}
