// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTermProtocol",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DanTermProtocol", targets: ["DanTermProtocol"]),
    ],
    targets: [
        .target(
            name: "DanTermProtocol",
            path: "Sources/DanTermProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermProtocolTests",
            dependencies: ["DanTermProtocol"],
            path: "Tests/DanTermProtocolTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
