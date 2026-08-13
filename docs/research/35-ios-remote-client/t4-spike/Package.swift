// swift-tools-version: 6.2
// Throwaway T4 evidence generator: a second macOS process that follows a pane tape over the
// control socket and drives its own TerminalCore. Not part of the app build or `just test`.
import PackageDescription

let package = Package(
    name: "T4ThinClient",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "t4-thin-client", targets: ["T4ThinClient"]),
    ],
    dependencies: [
        .package(path: "../../../../lib/TerminalCore"),
        .package(path: "../../../../lib/DanTermProtocol"),
    ],
    targets: [
        .executableTarget(
            name: "T4ThinClient",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "Sources/T4ThinClient",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
