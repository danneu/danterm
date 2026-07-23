// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "TerminalCoreRecording", targets: ["TerminalCoreRecording"]),
        .library(name: "TerminalSpriteGeometry", targets: ["TerminalSpriteGeometry"]),
        .library(name: "TerminalRenderPlanning", targets: ["TerminalRenderPlanning"]),
        .library(name: "TerminalRenderExecution", targets: ["TerminalRenderExecution"]),
        .executable(name: "TerminalCoreBenchmark", targets: ["TerminalCoreBenchmark"]),
        .executable(name: "TerminalDrawBenchmark", targets: ["TerminalDrawBenchmark"]),
        .executable(name: "GlyphPreview", targets: ["GlyphPreview"]),
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
            name: "TerminalSpriteGeometry",
            path: "Sources/TerminalSpriteGeometry",
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
            dependencies: ["TerminalRenderPlanning", "TerminalSpriteGeometry"],
            path: "Sources/TerminalRenderExecution",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalCoreBenchmark",
            dependencies: ["TerminalCoreBenchmarkSupport"],
            path: "Sources/TerminalCoreBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalCoreBenchmarkSupport",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalCoreBenchmarkSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalDrawBenchmark",
            dependencies: ["TerminalDrawBenchmarkSupport"],
            path: "Sources/TerminalDrawBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GlyphPreview",
            dependencies: ["TerminalCore", "TerminalRenderPlanning", "TerminalRenderExecution"],
            path: "Sources/GlyphPreview",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalDrawBenchmarkSupport",
            dependencies: ["TerminalCore", "TerminalRenderPlanning", "TerminalRenderExecution"],
            path: "Sources/TerminalDrawBenchmarkSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalDrawBenchmarkSupportTests",
            dependencies: ["TerminalDrawBenchmarkSupport", "TerminalCore", "TerminalRenderPlanning"],
            path: "Tests/TerminalDrawBenchmarkSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalCoreBenchmarkSupportTests",
            dependencies: ["TerminalCoreBenchmarkSupport", "TerminalCore"],
            path: "Tests/TerminalCoreBenchmarkSupportTests",
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
            name: "TerminalSpriteGeometryTests",
            dependencies: ["TerminalSpriteGeometry"],
            path: "Tests/TerminalSpriteGeometryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalRenderExecutionTests",
            dependencies: ["TerminalRenderExecution", "TerminalRenderPlanning", "TerminalCore"],
            path: "Tests/TerminalRenderExecutionTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GlyphPreviewTests",
            dependencies: ["GlyphPreview"],
            path: "Tests/GlyphPreviewTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
