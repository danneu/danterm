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
        .library(name: "TerminalBenchmarkMarkers", targets: ["TerminalBenchmarkMarkers"]),
        .library(name: "TerminalBenchmarkTopology", targets: ["TerminalBenchmarkTopology"]),
        .library(name: "TerminalBenchmarkCoverage", targets: ["TerminalBenchmarkCoverage"]),
        .executable(name: "TerminalCoreBenchmark", targets: ["TerminalCoreBenchmark"]),
        .executable(name: "TerminalDrawBenchmark", targets: ["TerminalDrawBenchmark"]),
        .executable(name: "GlyphPreview", targets: ["GlyphPreview"]),
        .executable(name: "TerminalMemoryProbe", targets: ["TerminalMemoryProbe"]),
        .executable(name: "TerminalOccupancyProbe", targets: ["TerminalOccupancyProbe"]),
        .executable(name: "TerminalBrowseBenchmark", targets: ["TerminalBrowseBenchmark"]),
        .executable(name: "TerminalResizeProbe", targets: ["TerminalResizeProbe"]),
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
            resources: [.copy("Resources/NerdFontsSymbolsOnly")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalCoreBenchmark",
            dependencies: ["TerminalCoreBenchmarkSupport"],
            path: "Sources/TerminalCoreBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalMemoryProbe",
            dependencies: ["TerminalMemoryProbeSupport", "TerminalCore"],
            path: "Sources/TerminalMemoryProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalMemoryProbeSupport",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalMemoryProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalOccupancyProbe",
            dependencies: ["TerminalOccupancyProbeSupport"],
            path: "Sources/TerminalOccupancyProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalOccupancyProbeSupport",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalOccupancyProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalOccupancyProbeSupportTests",
            dependencies: ["TerminalOccupancyProbeSupport", "TerminalCore"],
            path: "Tests/TerminalOccupancyProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalMemoryProbeSupportTests",
            dependencies: ["TerminalMemoryProbeSupport", "TerminalCore"],
            path: "Tests/TerminalMemoryProbeSupportTests",
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
            name: "TerminalBrowseBenchmark",
            dependencies: ["TerminalBrowseBenchmarkSupport"],
            path: "Sources/TerminalBrowseBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalResizeProbe",
            dependencies: ["TerminalResizeProbeSupport"],
            path: "Sources/TerminalResizeProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalResizeProbeSupport",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalResizeProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalBrowseBenchmarkSupport",
            dependencies: ["TerminalCore", "TerminalRenderPlanning"],
            path: "Sources/TerminalBrowseBenchmarkSupport",
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
        .target(
            name: "TerminalBenchmarkMarkers",
            dependencies: ["TerminalRenderPlanning"],
            path: "Sources/TerminalBenchmarkMarkers",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalBenchmarkTopology",
            dependencies: ["TerminalCore", "TerminalRenderPlanning"],
            path: "Sources/TerminalBenchmarkTopology",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalBenchmarkCoverage",
            path: "Sources/TerminalBenchmarkCoverage",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalBenchmarkCoverageTests",
            dependencies: ["TerminalBenchmarkCoverage"],
            path: "Tests/TerminalBenchmarkCoverageTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalBenchmarkTopologyTests",
            dependencies: ["TerminalBenchmarkTopology", "TerminalCore"],
            path: "Tests/TerminalBenchmarkTopologyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalBenchmarkMarkersTests",
            dependencies: ["TerminalBenchmarkMarkers", "TerminalCore", "TerminalRenderPlanning"],
            path: "Tests/TerminalBenchmarkMarkersTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalResizeProbeSupportTests",
            dependencies: ["TerminalResizeProbeSupport", "TerminalCore"],
            path: "Tests/TerminalResizeProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalBrowseBenchmarkSupportTests",
            dependencies: [
                "TerminalBrowseBenchmarkSupport", "TerminalCore", "TerminalRenderPlanning",
            ],
            path: "Tests/TerminalBrowseBenchmarkSupportTests",
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
