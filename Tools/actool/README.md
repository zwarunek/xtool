# actool for Linux

A replacement for Xcode's `actool` that compiles asset catalogs (`.xcassets`) on Linux into the same
`Assets.car` format CoreUI reads on iOS. It accepts the command line Swift Build passes to `actool`, so
`swift build --build-system swiftbuild --triple arm64-apple-ios` (and `xtool dev`) can build packages and
apps whose resources include asset catalogs.

## Install

Swift Build looks for `actool` in the Swift toolchain's `usr/bin` first, then in the platform tool
directories of the Darwin SDK (`Developer/Platforms/iPhoneOS.platform/Developer/usr/bin` and the
simulator one); it does not search `PATH`. `Scripts/install.sh` builds a self-contained binary and installs
it into the SDK that `xtool sdk install` created (override with `XTOOL_DARWIN_SDK`):

```sh
Tools/actool/Scripts/install.sh
```

Remove any `actool` from the toolchain's `usr/bin` (for example a stub or a dangling symlink), since it
would win. Copying the binary into the toolchain's `usr/bin` instead also works.

## What it compiles

| Catalog content | Output |
|---|---|
| Image sets: PNG, GIF, BMP, TIFF | Pixel renditions (premultiplied BGRA, or gray + alpha for gray images), LZFSE-compressed |
| Image sets: JPEG | JPEG renditions, stored as is |
| Image sets: SVG, PDF | Rasters at 1x, 2x and 3x plus the vector document (part 42 with *Preserve Vector Data*) |
| Template rendering intent, appearances (dark, light, high contrast), idioms, size classes, locales, resizing (3- and 9-part), alignment insets | Rendition flags, keys, slices and metrics as actool writes them |
| Color sets: sRGB, Display P3, extended sRGB, extended linear sRGB, gray gamma 2.2, extended gray; decimal, `0x` and 0-255 components | Color renditions |
| Data sets | Raw data renditions with their UTI |
| App icons: single-size (1024pt) and multi-size, appearances, alternate icons | Icon renditions, `<Name>60x60@2x.png` and `<Name>76x76@2x~ipad.png`, and the `CFBundleIcons` keys of the partial Info.plist |
| Symbol sets (SF Symbols template v7 SVGs) | Vector glyph renditions per weight and size, with glyph metrics |
| Icon Composer icons (`.icon` inputs) | A flattened 1024pt app icon (fill plus image layers), its PNGs and Info.plist keys |
| `--generate-swift-asset-symbols`, `--generate-objc-asset-symbols`, `--generate-asset-symbol-index` | `GeneratedAssetSymbols.swift`, `.h` and index plist (the asset symbol invocation writes only these, as actool does) |

It also writes the dependency info file (`--export-dependency-info`), the partial Info.plist, answers
`--version` and `--print-asset-tag-combinations`, and reports results in the `human-readable-text` and
`xml1` formats.

Not supported: system color references in color sets (skipped with a warning), sticker packs, tvOS
image stacks and brand assets, on-demand resource tags, the Liquid Glass layer stack and the dark and
tinted variants actool derives from `.icon` files (the flat icon is used for every appearance), and
Apple's image atlas packing (each image is stored on its own, which CoreUI also reads).

## Fidelity

Checked against Xcode 26.5's actool on 44 real catalogs and the synthetic catalog in
`Tests/ActoolKitTests/Fixtures`, by asking CoreUI on macOS (`Scripts/carcheck.m`) to resolve every image
(each scale, idiom and appearance), color, data set, app icon size and symbol glyph from both files and
comparing the results pixel by pixel. Known differences, all from Apple's renderers rather than the file
format:

- SVG masks: CoreSVG draws mask edges without anti-aliasing; this tool anti-aliases them.
- SVG gradients: CoreSVG interpolates them in a wider color space, so its colors come out less saturated.
- A few SVGs whose only path uses `fill-opacity` come out fully opaque from actool.
- Images resized from a 1024pt app icon differ slightly because of the resampling filter.
- Icons flattened from `.icon` files lack the glass rim and shadow actool renders.

## Tests

```sh
swift test --build-system native
```

`CompileTests` compiles the synthetic catalog and compares it with actool's output for the same catalog
(`Fixtures/Reference`). `RealCatalogTests` compares any set of catalogs against actool outputs made with
`Scripts/make-references.sh` when `ACTOOL_REAL_CATALOGS` and `ACTOOL_REAL_REFERENCES` are set.
`actool --compare-car reference.car candidate.car` runs the same structural comparison from the command line.

To refresh the references after changing the synthetic catalog, run on a Mac with Xcode:

```sh
python3 Scripts/make-synth-catalog.py Tests/ActoolKitTests/Fixtures/Synth.xcassets
```

then compile it with `xcrun actool` for iOS 26, 17 and 15 as `CompileTests` does and copy `Assets.car`,
`partial.plist`, the icon PNGs and the generated symbol files into `Fixtures/Reference/<variant>`.

## Third-party code

`Sources/CXTVendor` contains [lunasvg](https://github.com/sammycage/lunasvg) and plutovg (MIT; its rasterizer is FreeType-derived, see `plutovg/FTL.TXT`),
[lzfse](https://github.com/lzfse/lzfse) (BSD-3-Clause), and `stb_image_resize2.h` (public domain / MIT),
each with its license file.
