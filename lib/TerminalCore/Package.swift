// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "TerminalCoreRecording", targets: ["TerminalCoreRecording"]),
        .library(name: "TerminalRenderPlanning", targets: ["TerminalRenderPlanning"]),
        .library(name: "TerminalRenderExecution", targets: ["TerminalRenderExecution"]),
    ],
    targets: [
        .target(
            name: "TerminalCore",
            path: "Sources/TerminalCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalCoreRecording",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalCoreRecording",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalRenderPlanning",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalRenderPlanning",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalRenderExecution",
            dependencies: ["TerminalRenderPlanning"],
            path: "Sources/TerminalRenderExecution",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: [
                "TerminalCore",
                "TerminalCoreRecording",
            ],
            path: "Tests/TerminalCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalRenderPlanningTests",
            dependencies: ["TerminalRenderPlanning", "TerminalCore", "TerminalCoreRecording"],
            path: "Tests/TerminalRenderPlanningTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalRenderExecutionTests",
            dependencies: ["TerminalRenderExecution", "TerminalRenderPlanning", "TerminalCore"],
            path: "Tests/TerminalRenderExecutionTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
