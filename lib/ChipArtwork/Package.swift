// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChipArtwork",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ChipArtwork", targets: ["ChipArtwork"]),
    ],
    dependencies: [
        .package(path: "../DanTermProtocol"),
    ],
    targets: [
        .target(
            name: "ChipArtwork",
            dependencies: [
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "Sources/ChipArtwork",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ChipArtworkTests",
            dependencies: [
                "ChipArtwork",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "Tests/ChipArtworkTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
