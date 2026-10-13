// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "actool",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "actool", targets: ["actool"]),
        .library(name: "ActoolKit", targets: ["ActoolKit"]),
    ],
    targets: [
        .target(
            name: "CXTVendor",
            exclude: [
                "lunasvg/LICENSE",
                "plutovg/LICENSE",
                "plutovg/FTL.TXT",
                "lzfse/LICENSE",
            ],
            cSettings: [
                .define("PLUTOVG_BUILD"),
                .define("PLUTOVG_BUILD_STATIC"),
                .unsafeFlags(["-w", "-O2"]),
            ],
            cxxSettings: [
                .define("LUNASVG_BUILD"),
                .define("LUNASVG_BUILD_STATIC"),
                .define("PLUTOVG_BUILD_STATIC"),
                .define("LUNASVG_DISABLE_LOAD_SYSTEM_FONTS"),
                .unsafeFlags(["-w", "-O2"]),
            ]
        ),
        .target(
            name: "ActoolKit",
            dependencies: ["CXTVendor"]
        ),
        .executableTarget(
            name: "actool",
            dependencies: ["ActoolKit"]
        ),
        .testTarget(
            name: "ActoolKitTests",
            dependencies: ["ActoolKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
