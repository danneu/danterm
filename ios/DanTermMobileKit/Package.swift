// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTermMobileKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DanTermMobileKit", targets: ["DanTermMobileKit"]),
    ],
    dependencies: [
        .package(path: "../../lib/TerminalCore"),
        .package(path: "../../lib/DanTermProtocol"),
        .package(path: "../../lib/DanTermClient"),
    ],
    targets: [
        .target(
            name: "DanTermMobileKit",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
                .product(name: "DanTermClient", package: "DanTermClient"),
            ],
            path: "Sources/DanTermMobileKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DanTermMobileKitTests",
            dependencies: [
                "DanTermMobileKit",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
                .product(name: "DanTermClient", package: "DanTermClient"),
            ],
            path: "Tests/DanTermMobileKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
