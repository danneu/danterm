// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTermClient",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DanTermClient", targets: ["DanTermClient"]),
    ],
    dependencies: [
        .package(path: "../DanTermProtocol"),
    ],
    targets: [
        .target(
            name: "DanTermClient",
            dependencies: [
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "Sources/DanTermClient",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermClientTests",
            dependencies: [
                "DanTermClient",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "Tests/DanTermClientTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
