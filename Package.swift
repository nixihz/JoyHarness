// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            path: "Sources/AgentDeck",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("GameController"),
                .linkedFramework("CoreHaptics"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AgentDeck/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "AgentDeckTests",
            dependencies: ["AgentDeck"],
            path: "Tests/AgentDeckTests"
        ),
    ]
)
