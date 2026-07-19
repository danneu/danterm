// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalPTY",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaneLifecycle", targets: ["PaneLifecycle"]),
    ],
    targets: [
        .target(
            name: "PaneLifecycle",
            path: "Sources/PaneLifecycle",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PaneLifecycleTests",
            dependencies: ["PaneLifecycle"],
            path: "Tests/PaneLifecycleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
