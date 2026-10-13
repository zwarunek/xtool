// 
// GeneratedStringSymbols_Localizable.swift
// Auto-Generated symbols for localized strings defined in “Localizable.xcstrings”.
// 

import Foundation

#if SWIFT_PACKAGE
private nonisolated let resourceBundle = Foundation.Bundle.module
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.atURL(resourceBundle.bundleURL)
#else

private class ResourceBundleClass {}
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.forClass(ResourceBundleClass.self)
#endif

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
nonisolated extension LocalizedStringResource {
    /**
     Localized string for key “123leading” in table “Localizable.xcstrings”.
     */
    static var _123Leading: LocalizedStringResource {
        LocalizedStringResource("123leading", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “ALLCAPS” in table “Localizable.xcstrings”.
     */
    static var allcaps: LocalizedStringResource {
        LocalizedStringResource("ALLCAPS", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “HTTPStatus” in table “Localizable.xcstrings”.
     */
    static var httpstatus: LocalizedStringResource {
        LocalizedStringResource("HTTPStatus", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “ID” in table “Localizable.xcstrings”.
     */
    static var id: LocalizedStringResource {
        LocalizedStringResource("ID", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “PascalCase” in table “Localizable.xcstrings”.
     */
    static var pascalCase: LocalizedStringResource {
        LocalizedStringResource("PascalCase", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %@
     
     Localized string for key “SPEC_00” in table “Localizable.xcstrings”.
     */
    static func spec00(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_00", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %d
     
     Localized string for key “SPEC_01” in table “Localizable.xcstrings”.
     */
    static func spec01(_ arg1: Int32) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_01", defaultValue: "\(arg1, specifier: "%d")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %ld
     
     Localized string for key “SPEC_03” in table “Localizable.xcstrings”.
     */
    static func spec03(_ arg1: Int) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_03", defaultValue: "\(arg1, specifier: "%ld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %lld
     
     Localized string for key “SPEC_04” in table “Localizable.xcstrings”.
     */
    static func spec04(_ arg1: Int) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_04", defaultValue: "\(arg1, specifier: "%lld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %u
     
     Localized string for key “SPEC_05” in table “Localizable.xcstrings”.
     */
    static func spec05(_ arg1: UInt32) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_05", defaultValue: "\(arg1, specifier: "%u")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %lu
     
     Localized string for key “SPEC_06” in table “Localizable.xcstrings”.
     */
    static func spec06(_ arg1: UInt) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_06", defaultValue: "\(arg1, specifier: "%lu")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %llu
     
     Localized string for key “SPEC_07” in table “Localizable.xcstrings”.
     */
    static func spec07(_ arg1: UInt) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_07", defaultValue: "\(arg1, specifier: "%llu")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %f
     
     Localized string for key “SPEC_08” in table “Localizable.xcstrings”.
     */
    static func spec08(_ arg1: Float) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_08", defaultValue: "\(arg1, specifier: "%f")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %lf
     
     Localized string for key “SPEC_09” in table “Localizable.xcstrings”.
     */
    static func spec09(_ arg1: Double) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_09", defaultValue: "\(arg1, specifier: "%lf")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %.2f
     
     Localized string for key “SPEC_10” in table “Localizable.xcstrings”.
     */
    static func spec10(_ arg1: Float) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_10", defaultValue: "\(arg1, specifier: "%.2f")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %g
     
     Localized string for key “SPEC_12” in table “Localizable.xcstrings”.
     */
    static func spec12(_ arg1: Double) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_12", defaultValue: "\(arg1, specifier: "%g")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %5.1f
     
     Localized string for key “SPEC_27” in table “Localizable.xcstrings”.
     */
    static func spec27(_ arg1: Float) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_27", defaultValue: "\(arg1, specifier: "%5.1f")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %-3d
     
     Localized string for key “SPEC_28” in table “Localizable.xcstrings”.
     */
    static func spec28(_ arg1: Int32) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_28", defaultValue: "\(arg1, specifier: "%-3d")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %+d
     
     Localized string for key “SPEC_29” in table “Localizable.xcstrings”.
     */
    static func spec29(_ arg1: Int32) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_29", defaultValue: "\(arg1, specifier: "%+d")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %1$@
     
     Localized string for key “SPEC_31” in table “Localizable.xcstrings”.
     */
    static func spec31(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_31", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %2$@ %1$lld
     
     Localized string for key “SPEC_32” in table “Localizable.xcstrings”.
     */
    static func spec32(_ arg1: Int, _ arg2: String) -> LocalizedStringResource {
        LocalizedStringResource("SPEC_32", defaultValue: "\(arg1, specifier: "%lld")\(arg2)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     spec %%
     
     Localized string for key “SPEC_33” in table “Localizable.xcstrings”.
     */
    static var spec33: LocalizedStringResource {
        LocalizedStringResource("SPEC_33", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “UPPER_SNAKE” in table “Localizable.xcstrings”.
     */
    static var upperSnake: LocalizedStringResource {
        LocalizedStringResource("UPPER_SNAKE", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “URL_HANDLER” in table “Localizable.xcstrings”.
     */
    static var urlHandler: LocalizedStringResource {
        LocalizedStringResource("URL_HANDLER", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “__double” in table “Localizable.xcstrings”.
     */
    static var _Double: LocalizedStringResource {
        LocalizedStringResource("__double", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “back\slash” in table “Localizable.xcstrings”.
     */
    static var backSlash: LocalizedStringResource {
        LocalizedStringResource("back\\slash", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “camelCase” in table “Localizable.xcstrings”.
     */
    static var camelCase: LocalizedStringResource {
        LocalizedStringResource("camelCase", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “class” in table “Localizable.xcstrings”.
     */
    static var `class`: LocalizedStringResource {
        LocalizedStringResource("class", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     
     
     Localized string for key “comment_empty” in table “Localizable.xcstrings”.
     */
    static var commentEmpty: LocalizedStringResource {
        LocalizedStringResource("comment_empty", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Line one
Line two with * / and “quotes” and \(interp)
     
     Localized string for key “comment_multi” in table “Localizable.xcstrings”.
     */
    static var commentMulti: LocalizedStringResource {
        LocalizedStringResource("comment_multi", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “dash-key” in table “Localizable.xcstrings”.
     */
    static var dashKey: LocalizedStringResource {
        LocalizedStringResource("dash-key", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “default” in table “Localizable.xcstrings”.
     */
    static var `default`: LocalizedStringResource {
        LocalizedStringResource("default", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “device_diff_args” in table “Localizable.xcstrings”.
     */
    static func deviceDiffArgs(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("device_diff_args", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “device_manual” in table “Localizable.xcstrings”.
     */
    static func deviceManual(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("device_manual", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “dots.in.key” in table “Localizable.xcstrings”.
     */
    static var dotsInKey: LocalizedStringResource {
        LocalizedStringResource("dots.in.key", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “has"quote” in table “Localizable.xcstrings”.
     */
    static var hasQuote: LocalizedStringResource {
        LocalizedStringResource("has\"quote", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “k$dollar” in table “Localizable.xcstrings”.
     */
    static var k$Dollar: LocalizedStringResource {
        LocalizedStringResource("k$dollar", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “key with émoji 😀” in table “Localizable.xcstrings”.
     */
    static var keyWithÉmoji😀: LocalizedStringResource {
        LocalizedStringResource("key with émoji 😀", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “mixed_Case_key” in table “Localizable.xcstrings”.
     */
    static var mixedCaseKey: LocalizedStringResource {
        LocalizedStringResource("mixed_Case_key", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “myURLHandler” in table “Localizable.xcstrings”.
     */
    static var myURLHandler: LocalizedStringResource {
        LocalizedStringResource("myURLHandler", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “new
line” in table “Localizable.xcstrings”.
     */
    static var newLine: LocalizedStringResource {
        LocalizedStringResource("new\nline", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “new_state” in table “Localizable.xcstrings”.
     */
    static func newState(_ arg1: Int32) -> LocalizedStringResource {
        LocalizedStringResource("new_state", defaultValue: "\(arg1, specifier: "%d")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “no_en_loc” in table “Localizable.xcstrings”.
     */
    static func noEnLoc(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("no_en_loc", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “no_loc_at_all” in table “Localizable.xcstrings”.
     */
    static var noLocAtAll: LocalizedStringResource {
        LocalizedStringResource("no_loc_at_all", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “percent_literal” in table “Localizable.xcstrings”.
     */
    static func percentLiteral(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("percent_literal", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “plural_manual” in table “Localizable.xcstrings”.
     */
    static func pluralManual(_ arg1: Int) -> LocalizedStringResource {
        LocalizedStringResource("plural_manual", defaultValue: "\(arg1, specifier: "%lld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “plural_one_noarg” in table “Localizable.xcstrings”.
     */
    static func pluralOneNoarg(_ arg1: Int32) -> LocalizedStringResource {
        LocalizedStringResource("plural_one_noarg", defaultValue: "\(arg1, specifier: "%d")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “plural_two_args” in table “Localizable.xcstrings”.
     */
    static func pluralTwoArgs(_ arg1: String, _ arg2: Int) -> LocalizedStringResource {
        LocalizedStringResource("plural_two_args", defaultValue: "\(arg1)\(arg2, specifier: "%lld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “repeat_pos” in table “Localizable.xcstrings”.
     */
    static func repeatPos(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("repeat_pos", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “shouldnt_translate” in table “Localizable.xcstrings”.
     */
    static func shouldntTranslate(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("shouldnt_translate", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “simple” in table “Localizable.xcstrings”.
     */
    static var simple: LocalizedStringResource {
        LocalizedStringResource("simple", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “subs_manual %#@n@” in table “Localizable.xcstrings”.
     */
    static func subsManual1$N(_ arg1: String, n: Int) -> LocalizedStringResource {
        LocalizedStringResource("subs_manual %#@n@", defaultValue: "\(arg1)\(n, specifier: "%lld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “tab	key” in table “Localizable.xcstrings”.
     */
    static var tabKey: LocalizedStringResource {
        LocalizedStringResource("tab\tkey", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “trailing_” in table “Localizable.xcstrings”.
     */
    static var trailing: LocalizedStringResource {
        LocalizedStringResource("trailing_", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “two__underscores” in table “Localizable.xcstrings”.
     */
    static var twoUnderscores: LocalizedStringResource {
        LocalizedStringResource("two__underscores", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “unordered_pos” in table “Localizable.xcstrings”.
     */
    static func unorderedPos(_ arg1: Int32, _ arg2: String) -> LocalizedStringResource {
        LocalizedStringResource("unordered_pos", defaultValue: "\(arg1, specifier: "%d")\(arg2)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “with space key” in table “Localizable.xcstrings”.
     */
    static var withSpaceKey: LocalizedStringResource {
        LocalizedStringResource("with space key", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “x2y” in table “Localizable.xcstrings”.
     */
    static var x2Y: LocalizedStringResource {
        LocalizedStringResource("x2y", table: "Localizable", bundle: resourceBundleDescription)
    }
}