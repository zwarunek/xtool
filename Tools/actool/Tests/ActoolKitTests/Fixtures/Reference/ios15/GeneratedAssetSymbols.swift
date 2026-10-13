import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
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

@available(iOS 11.0, macOS 10.13, tvOS 11.0, *)
extension ColorResource {

    /// The "Colors" asset catalog resource namespace.
    enum Colors {

        /// The "Colors/c-ext-gray" asset catalog color resource.
        static let cExtGray = ColorResource(name: "Colors/c-ext-gray", bundle: resourceBundle)

        /// The "Colors/c-ext-lin-srgb" asset catalog color resource.
        static let cExtLinSrgb = ColorResource(name: "Colors/c-ext-lin-srgb", bundle: resourceBundle)

        /// The "Colors/c-ext-srgb" asset catalog color resource.
        static let cExtSrgb = ColorResource(name: "Colors/c-ext-srgb", bundle: resourceBundle)

        /// The "Colors/c-gray22" asset catalog color resource.
        static let cGray22 = ColorResource(name: "Colors/c-gray22", bundle: resourceBundle)

        /// The "Colors/c-p3" asset catalog color resource.
        static let cP3 = ColorResource(name: "Colors/c-p3", bundle: resourceBundle)

        /// The "Colors/c-srgb" asset catalog color resource.
        static let cSrgb = ColorResource(name: "Colors/c-srgb", bundle: resourceBundle)

        /// The "Colors/c-srgb-hex" asset catalog color resource.
        static let cSrgbHex = ColorResource(name: "Colors/c-srgb-hex", bundle: resourceBundle)

        /// The "Colors/c-srgb-int" asset catalog color resource.
        static let cSrgbInt = ColorResource(name: "Colors/c-srgb-int", bundle: resourceBundle)

        /// The "Colors/c-system" asset catalog color resource.
        static let cSystem = ColorResource(name: "Colors/c-system", bundle: resourceBundle)

    }

    /// The "c-appearances" asset catalog color resource.
    static let cAppearances = ColorResource(name: "c-appearances", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 11.0, macOS 10.7, tvOS 11.0, *)
extension ImageResource {

    /// The "i-3h" asset catalog image resource.
    static let i3H = ImageResource(name: "i-3h", bundle: resourceBundle)

    /// The "i-9part" asset catalog image resource.
    static let i9Part = ImageResource(name: "i-9part", bundle: resourceBundle)

    /// The "i-alignment" asset catalog image resource.
    static let iAlignment = ImageResource(name: "i-alignment", bundle: resourceBundle)

    /// The "i-appearance" asset catalog image resource.
    static let iAppearance = ImageResource(name: "i-appearance", bundle: resourceBundle)

    /// The "i-gray" asset catalog image resource.
    static let iGray = ImageResource(name: "i-gray", bundle: resourceBundle)

    /// The "i-idioms" asset catalog image resource.
    static let iIdioms = ImageResource(name: "i-idioms", bundle: resourceBundle)

    /// The "i-indexed" asset catalog image resource.
    static let iIndexed = ImageResource(name: "i-indexed", bundle: resourceBundle)

    /// The "i-locale" asset catalog image resource.
    static let iLocale = ImageResource(name: "i-locale", bundle: resourceBundle)

    /// The "i-opaque" asset catalog image resource.
    static let iOpaque = ImageResource(name: "i-opaque", bundle: resourceBundle)

    /// The "i-original" asset catalog image resource.
    static let iOriginal = ImageResource(name: "i-original", bundle: resourceBundle)

    /// The "i-single-scale" asset catalog image resource.
    static let iSingleScale = ImageResource(name: "i-single-scale", bundle: resourceBundle)

    /// The "i-sizeclass" asset catalog image resource.
    static let iSizeclass = ImageResource(name: "i-sizeclass", bundle: resourceBundle)

    /// The "i-template" asset catalog image resource.
    static let iTemplate = ImageResource(name: "i-template", bundle: resourceBundle)

    /// The "j-jpeg" asset catalog image resource.
    static let jJpeg = ImageResource(name: "j-jpeg", bundle: resourceBundle)

    /// The "sym-custom" asset catalog image resource.
    static let symCustom = ImageResource(name: "sym-custom", bundle: resourceBundle)

    /// The "v-pdf" asset catalog image resource.
    static let vPdf = ImageResource(name: "v-pdf", bundle: resourceBundle)

    /// The "v-pdf-2x" asset catalog image resource.
    static let vPdf2X = ImageResource(name: "v-pdf-2x", bundle: resourceBundle)

    /// The "v-pdf-preserve" asset catalog image resource.
    static let vPdfPreserve = ImageResource(name: "v-pdf-preserve", bundle: resourceBundle)

    /// The "v-svg" asset catalog image resource.
    static let vSvg = ImageResource(name: "v-svg", bundle: resourceBundle)

    /// The "v-svg-fractional" asset catalog image resource.
    static let vSvgFractional = ImageResource(name: "v-svg-fractional", bundle: resourceBundle)

    /// The "v-svg-gradient" asset catalog image resource.
    static let vSvgGradient = ImageResource(name: "v-svg-gradient", bundle: resourceBundle)

    /// The "v-svg-mask" asset catalog image resource.
    static let vSvgMask = ImageResource(name: "v-svg-mask", bundle: resourceBundle)

    /// The "v-svg-preserve-template" asset catalog image resource.
    static let vSvgPreserveTemplate = ImageResource(name: "v-svg-preserve-template", bundle: resourceBundle)

}

// MARK: - Backwards Deployment Support -

/// A color resource.
struct ColorResource: Swift.Hashable, Swift.Sendable {

    /// An asset catalog color resource name.
    fileprivate let name: Swift.String

    /// An asset catalog color resource bundle.
    fileprivate let bundle: Foundation.Bundle

    /// Initialize a `ColorResource` with `name` and `bundle`.
    init(name: Swift.String, bundle: Foundation.Bundle) {
        self.name = name
        self.bundle = bundle
    }

}

/// An image resource.
struct ImageResource: Swift.Hashable, Swift.Sendable {

    /// An asset catalog image resource name.
    fileprivate let name: Swift.String

    /// An asset catalog image resource bundle.
    fileprivate let bundle: Foundation.Bundle

    /// Initialize an `ImageResource` with `name` and `bundle`.
    init(name: Swift.String, bundle: Foundation.Bundle) {
        self.name = name
        self.bundle = bundle
    }

}

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