// swift-tools-version: 6.2
// Scratch package for the T2 spike: an iOS executable that renders one static
// RenderFramePlan. It lives here rather than in lib/ because it is throwaway
// evidence, not a product -- lib/TerminalCore has no iOS executable target and
// must not grow one until a decision (D2) says the client is real.
import PackageDescription

let package = Package(
    name: "IOSRenderSpike",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(path: "../../../../lib/TerminalCore"),
        // T23 links the shipped client end of the conversation rather than a
        // spike copy of it: whether `DanTermClient` builds into and works from
        // an iOS binary is the thing being tested.
        .package(path: "../../../../lib/DanTermClient"),
    ],
    targets: [
        .executableTarget(
            name: "IOSRenderSpike",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "DanTermClient", package: "DanTermClient"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
