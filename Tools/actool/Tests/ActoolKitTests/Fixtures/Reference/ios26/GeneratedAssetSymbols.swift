import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "Colors" asset catalog resource namespace.
    enum Colors {

        /// The "Colors/c-ext-gray" asset catalog color resource.
        static let cExtGray = DeveloperToolsSupport.ColorResource(name: "Colors/c-ext-gray", bundle: resourceBundle)

        /// The "Colors/c-ext-lin-srgb" asset catalog color resource.
        static let cExtLinSrgb = DeveloperToolsSupport.ColorResource(name: "Colors/c-ext-lin-srgb", bundle: resourceBundle)

        /// The "Colors/c-ext-srgb" asset catalog color resource.
        static let cExtSrgb = DeveloperToolsSupport.ColorResource(name: "Colors/c-ext-srgb", bundle: resourceBundle)

        /// The "Colors/c-gray22" asset catalog color resource.
        static let cGray22 = DeveloperToolsSupport.ColorResource(name: "Colors/c-gray22", bundle: resourceBundle)

        /// The "Colors/c-p3" asset catalog color resource.
        static let cP3 = DeveloperToolsSupport.ColorResource(name: "Colors/c-p3", bundle: resourceBundle)

        /// The "Colors/c-srgb" asset catalog color resource.
        static let cSrgb = DeveloperToolsSupport.ColorResource(name: "Colors/c-srgb", bundle: resourceBundle)

        /// The "Colors/c-srgb-hex" asset catalog color resource.
        static let cSrgbHex = DeveloperToolsSupport.ColorResource(name: "Colors/c-srgb-hex", bundle: resourceBundle)

        /// The "Colors/c-srgb-int" asset catalog color resource.
        static let cSrgbInt = DeveloperToolsSupport.ColorResource(name: "Colors/c-srgb-int", bundle: resourceBundle)

        /// The "Colors/c-system" asset catalog color resource.
        static let cSystem = DeveloperToolsSupport.ColorResource(name: "Colors/c-system", bundle: resourceBundle)

    }

    /// The "c-appearances" asset catalog color resource.
    static let cAppearances = DeveloperToolsSupport.ColorResource(name: "c-appearances", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "i-3h" asset catalog image resource.
    static let i3H = DeveloperToolsSupport.ImageResource(name: "i-3h", bundle: resourceBundle)

    /// The "i-9part" asset catalog image resource.
    static let i9Part = DeveloperToolsSupport.ImageResource(name: "i-9part", bundle: resourceBundle)

    /// The "i-alignment" asset catalog image resource.
    static let iAlignment = DeveloperToolsSupport.ImageResource(name: "i-alignment", bundle: resourceBundle)

    /// The "i-appearance" asset catalog image resource.
    static let iAppearance = DeveloperToolsSupport.ImageResource(name: "i-appearance", bundle: resourceBundle)

    /// The "i-gray" asset catalog image resource.
    static let iGray = DeveloperToolsSupport.ImageResource(name: "i-gray", bundle: resourceBundle)

    /// The "i-idioms" asset catalog image resource.
    static let iIdioms = DeveloperToolsSupport.ImageResource(name: "i-idioms", bundle: resourceBundle)

    /// The "i-indexed" asset catalog image resource.
    static let iIndexed = DeveloperToolsSupport.ImageResource(name: "i-indexed", bundle: resourceBundle)

    /// The "i-locale" asset catalog image resource.
    static let iLocale = DeveloperToolsSupport.ImageResource(name: "i-locale", bundle: resourceBundle)

    /// The "i-opaque" asset catalog image resource.
    static let iOpaque = DeveloperToolsSupport.ImageResource(name: "i-opaque", bundle: resourceBundle)

    /// The "i-original" asset catalog image resource.
    static let iOriginal = DeveloperToolsSupport.ImageResource(name: "i-original", bundle: resourceBundle)

    /// The "i-single-scale" asset catalog image resource.
    static let iSingleScale = DeveloperToolsSupport.ImageResource(name: "i-single-scale", bundle: resourceBundle)

    /// The "i-sizeclass" asset catalog image resource.
    static let iSizeclass = DeveloperToolsSupport.ImageResource(name: "i-sizeclass", bundle: resourceBundle)

    /// The "i-template" asset catalog image resource.
    static let iTemplate = DeveloperToolsSupport.ImageResource(name: "i-template", bundle: resourceBundle)

    /// The "j-jpeg" asset catalog image resource.
    static let jJpeg = DeveloperToolsSupport.ImageResource(name: "j-jpeg", bundle: resourceBundle)

    /// The "sym-custom" asset catalog image resource.
    static let symCustom = DeveloperToolsSupport.ImageResource(name: "sym-custom", bundle: resourceBundle)

    /// The "v-pdf" asset catalog image resource.
    static let vPdf = DeveloperToolsSupport.ImageResource(name: "v-pdf", bundle: resourceBundle)

    /// The "v-pdf-2x" asset catalog image resource.
    static let vPdf2X = DeveloperToolsSupport.ImageResource(name: "v-pdf-2x", bundle: resourceBundle)

    /// The "v-pdf-preserve" asset catalog image resource.
    static let vPdfPreserve = DeveloperToolsSupport.ImageResource(name: "v-pdf-preserve", bundle: resourceBundle)

    /// The "v-svg" asset catalog image resource.
    static let vSvg = DeveloperToolsSupport.ImageResource(name: "v-svg", bundle: resourceBundle)

    /// The "v-svg-fractional" asset catalog image resource.
    static let vSvgFractional = DeveloperToolsSupport.ImageResource(name: "v-svg-fractional", bundle: resourceBundle)

    /// The "v-svg-gradient" asset catalog image resource.
    static let vSvgGradient = DeveloperToolsSupport.ImageResource(name: "v-svg-gradient", bundle: resourceBundle)

    /// The "v-svg-mask" asset catalog image resource.
    static let vSvgMask = DeveloperToolsSupport.ImageResource(name: "v-svg-mask", bundle: resourceBundle)

    /// The "v-svg-preserve-template" asset catalog image resource.
    static let vSvgPreserveTemplate = DeveloperToolsSupport.ImageResource(name: "v-svg-preserve-template", bundle: resourceBundle)

}

