// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JoyHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CDualSenseControlClient", path: "Sources/CDualSenseControlClient", publicHeadersPath: "include"),
        // Fixed, portable Opus sources; statically linked, with no runtime dylib lookup.
        .target(
            name: "CJoyHarnessOpus",
            path: "Vendor/Opus",
            exclude: ["COPYING", "AUTHORS", "README.md", "UPSTREAM_FILES.json", "opus_sources.mk", "celt_sources.mk", "silk_sources.mk"],
            sources: ["JoyHarnessOpus.c", "src", "celt", "silk"],
            publicHeadersPath: "public",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS"),
                .define("HAVE_LRINT"),
                .define("HAVE_LRINTF"),
                .define("DISABLE_DEBUG_FLOAT"),
                .define("ENABLE_HARDENING"),
                .define("PACKAGE_VERSION", to: "\"1.5.2\""),
            ]
        ),
        .executableTarget(
            name: "JoyHarness",
            dependencies: [
                "CJoyHarnessOpus",
                "CDualSenseControlClient",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/JoyHarness",
            // Packaging scripts install the app icon into Contents/Resources directly.
            exclude: ["Info.plist", "DashboardPrototype", "Resources/JoyHarness.icns"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("GameController"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Security"),
                .linkedFramework("CoreHaptics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/JoyHarness/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "JoyHarnessTests",
            dependencies: ["JoyHarness"],
            path: "Tests/JoyHarnessTests"
        ),
    ]
)
