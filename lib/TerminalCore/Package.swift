// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
    ],
    targets: [
        .target(
            name: "TerminalCore",
            path: "Sources/TerminalCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"],
            path: "Tests/TerminalCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
