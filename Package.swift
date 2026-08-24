// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JoyHarness",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JoyHarness",
            path: "Sources/JoyHarness",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("GameController"),
                .linkedFramework("CoreHaptics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/JoyHarness/Info.plist",
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
