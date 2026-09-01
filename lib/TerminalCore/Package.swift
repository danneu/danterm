// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "TerminalCoreRecording", targets: ["TerminalCoreRecording"]),
        .library(name: "TerminalSpriteGeometry", targets: ["TerminalSpriteGeometry"]),
        .library(name: "TerminalRenderPlanning", targets: ["TerminalRenderPlanning"]),
        .library(name: "TerminalRenderExecution", targets: ["TerminalRenderExecution"]),
        .library(name: "TerminalBenchmarkMarkers", targets: ["TerminalBenchmarkMarkers"]),
        .library(name: "TerminalBenchmarkTopology", targets: ["TerminalBenchmarkTopology"]),
        .library(name: "TerminalBenchmarkCoverage", targets: ["TerminalBenchmarkCoverage"]),
        .library(name: "TerminalMemoryProbeSupport", targets: ["TerminalMemoryProbeSupport"]),
        .library(name: "TerminalProbeArguments", targets: ["TerminalProbeArguments"]),
        .executable(name: "TerminalCoreBenchmark", targets: ["TerminalCoreBenchmark"]),
        .executable(name: "TerminalDrawBenchmark", targets: ["TerminalDrawBenchmark"]),
        .executable(name: "TerminalOccupancyProbe", targets: ["TerminalOccupancyProbe"]),
        .executable(name: "TerminalBrowseBenchmark", targets: ["TerminalBrowseBenchmark"]),
        .executable(name: "TerminalResizeProbe", targets: ["TerminalResizeProbe"]),
        .executable(name: "TerminalRetainedRowProbe", targets: ["TerminalRetainedRowProbe"]),
        .executable(name: "TerminalRecordingReplay", targets: ["TerminalRecordingReplay"]),
        .executable(name: "TerminalValueLayoutProbe", targets: ["TerminalValueLayoutProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
    ],
    targets: [
        .target(
            name: "TerminalCore",
            dependencies: [
                .product(name: "BitCollections", package: "swift-collections"),
                .product(name: "DequeModule", package: "swift-collections"),
            ],
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
            dependencies: ["TerminalCoreBenchmarkSupport", "KittenFeedFixture"],
            path: "Sources/TerminalCoreBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // No dependency on TerminalCore on purpose: this target knows flag names, kinds, and
        // ranges, and nothing about what a terminal can represent. Keeping it that way is what
        // lets every probe and benchmark in this package depend on it without a cycle.
        // The one thing `scripts/terminal-self-copy-gate.py` cannot read out of a
        // disassembly: how many bytes a `Terminal` value is in the build it is about to
        // disassemble. It has no support module and no test target because it holds no
        // logic -- it prints two `MemoryLayout` numbers.
        .executableTarget(
            name: "TerminalValueLayoutProbe",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalValueLayoutProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalProbeArguments",
            path: "Sources/TerminalProbeArguments",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalProbeArgumentsTests",
            dependencies: ["TerminalProbeArguments"],
            path: "Tests/TerminalProbeArgumentsTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalMemoryProbeSupport",
            dependencies: ["TerminalCore", "TerminalProbeArguments"],
            path: "Sources/TerminalMemoryProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalOccupancyProbe",
            dependencies: ["TerminalOccupancyProbeSupport", "TerminalProbeArguments"],
            path: "Sources/TerminalOccupancyProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalOccupancyProbeSupport",
            dependencies: ["TerminalCore", "TerminalProbeArguments"],
            path: "Sources/TerminalOccupancyProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalOccupancyProbeSupportTests",
            dependencies: [
                "TerminalOccupancyProbeSupport", "TerminalCore", "TerminalProbeArguments",
            ],
            path: "Tests/TerminalOccupancyProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalMemoryProbeSupportTests",
            dependencies: [
                "TerminalMemoryProbeSupport", "TerminalCore", "TerminalProbeArguments",
            ],
            path: "Tests/TerminalMemoryProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalCoreBenchmarkSupport",
            dependencies: ["TerminalCore"],
            path: "Sources/TerminalCoreBenchmarkSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // No dependency on TerminalCore on purpose: the kitten arms are a byte stimulus,
        // not a terminal, and keeping them apart is what lets the parity lint treat this
        // target as the single definition of what each arm sends.
        .target(
            name: "KittenFeedFixture",
            path: "Sources/KittenFeedFixture",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalDrawBenchmark",
            dependencies: ["TerminalDrawBenchmarkSupport"],
            path: "Sources/TerminalDrawBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Declared here only so the gate compiles it. The measurement builds this same
        // source into two generated packages of its own, one per TerminalCore checkout --
        // see the source header. Nothing in this package depends on it; its test target is
        // what makes `swift test` build it.
        .executableTarget(
            name: "TerminalRecordingReplay",
            dependencies: ["TerminalCore", "TerminalCoreRecording"],
            path: "Sources/TerminalRecordingReplay",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "HeadlessDrawArm",
            dependencies: [
                "TerminalCore",
                "TerminalRenderPlanning",
                "TerminalRenderExecution",
            ],
            path: "Sources/HeadlessDrawArm",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HeadlessDrawArmTests",
            dependencies: ["HeadlessDrawArm", "TerminalDrawBenchmarkSupport"],
            path: "Tests/HeadlessDrawArmTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalBrowseBenchmark",
            dependencies: ["TerminalBrowseBenchmarkSupport", "TerminalProbeArguments"],
            path: "Sources/TerminalBrowseBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalResizeProbe",
            dependencies: ["TerminalResizeProbeSupport", "TerminalProbeArguments"],
            path: "Sources/TerminalResizeProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalResizeProbeSupport",
            dependencies: ["TerminalCore", "TerminalProbeArguments"],
            path: "Sources/TerminalResizeProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalRetainedRowProbe",
            dependencies: [
                "TerminalRetainedRowProbeSupport", "TerminalCoreBenchmarkSupport",
                "TerminalProbeArguments",
            ],
            path: "Sources/TerminalRetainedRowProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalRetainedRowProbeSupport",
            dependencies: ["TerminalCore", "TerminalProbeArguments"],
            path: "Sources/TerminalRetainedRowProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalRetainedRowProbeSupportTests",
            dependencies: [
                "TerminalRetainedRowProbeSupport", "TerminalCore", "TerminalProbeArguments",
            ],
            path: "Tests/TerminalRetainedRowProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalBrowseBenchmarkSupport",
            dependencies: ["TerminalCore", "TerminalRenderPlanning", "TerminalProbeArguments"],
            path: "Sources/TerminalBrowseBenchmarkSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalDrawBenchmarkSupport",
            dependencies: [
                "TerminalCore",
                "TerminalCoreBenchmarkSupport",
                "TerminalRenderPlanning",
                "TerminalRenderExecution",
            ],
            path: "Sources/TerminalDrawBenchmarkSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalBenchmarkMarkers",
            dependencies: ["TerminalCore", "TerminalRenderPlanning"],
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
            dependencies: [
                "TerminalResizeProbeSupport", "TerminalCore", "TerminalProbeArguments",
            ],
            path: "Tests/TerminalResizeProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalBrowseBenchmarkSupportTests",
            dependencies: [
                "TerminalBrowseBenchmarkSupport", "TerminalCore", "TerminalRenderPlanning",
                "TerminalProbeArguments",
            ],
            path: "Tests/TerminalBrowseBenchmarkSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalDrawBenchmarkSupportTests",
            dependencies: [
                "TerminalDrawBenchmarkSupport",
                "TerminalCore",
                "TerminalRenderPlanning",
                "TerminalRenderExecution",
                "TerminalSpriteGeometry",
            ],
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
            name: "KittenFeedFixtureTests",
            dependencies: ["KittenFeedFixture", "TerminalCore"],
            path: "Tests/KittenFeedFixtureTests",
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
    ]
)
