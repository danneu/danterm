// swift-tools-version: 6.2
// Throwaway T9 evidence generator: replays the iOS client's own persisted replica checkpoint
// into a headless TerminalCore on the Mac, so a reconnect's exactness is asserted on state the
// screen does not restore by itself. Not part of the app build or `just test`.
import PackageDescription

let package = Package(
    name: "T9Checkpoint",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "t9-checkpoint", targets: ["T9Checkpoint"]),
    ],
    dependencies: [
        .package(path: "../../../../lib/TerminalCore"),
    ],
    targets: [
        .executableTarget(
            name: "T9Checkpoint",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
            ],
            path: "Sources/T9Checkpoint",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
