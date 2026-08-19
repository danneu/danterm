// swift-tools-version: 6.2
// Builds the iOS-only UIKit shell without introducing an Xcode project.
import PackageDescription

let package = Package(
    name: "DanTermMobileApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(path: "../DanTermMobileKit"),
        .package(path: "../../lib/TerminalCore"),
        .package(path: "../../lib/DanTermProtocol"),
        .package(path: "../../lib/DanTermClient"),
        .package(path: "../../lib/ChipArtwork"),
    ],
    targets: [
        .executableTarget(
            name: "DanTermMobileApp",
            dependencies: [
                .product(name: "DanTermMobileKit", package: "DanTermMobileKit"),
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
                .product(name: "DanTermClient", package: "DanTermClient"),
                .product(name: "ChipArtwork", package: "ChipArtwork"),
            ],
            path: "Sources/DanTermMobileApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
