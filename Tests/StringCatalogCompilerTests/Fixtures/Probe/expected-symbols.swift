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
     Localized string for key “ext_manual” in table “Localizable.xcstrings”.
     */
    static var extManual: LocalizedStringResource {
        LocalizedStringResource("ext_manual", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “notr_manual” in table “Localizable.xcstrings”.
     */
    static var notrManual: LocalizedStringResource {
        LocalizedStringResource("notr_manual", table: "Localizable", bundle: resourceBundleDescription)
    }
}