// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JoyHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "JoyHarness",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/JoyHarness",
            exclude: ["Info.plist", "DashboardPrototype"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("GameController"),
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
