// swift-tools-version: 6.2
// Scratch package for the T5 bridge prototype: a macOS executable that proxies
// the DanTerm control socket onto the tailnet so a phone can reach it.
//
// It lives here rather than in lib/ because it is throwaway evidence for F5, not
// the shipped bridge. T6 owns the auth model and weighs the ideal alternative --
// the app listening on the network itself -- so nothing here may become the
// product by default.
//
// macOS only, and deliberately unpinned for iOS: this is the Mac host's side.
import PackageDescription

let package = Package(
    name: "T5Bridge",
    platforms: [.macOS(.v26)],
    dependencies: [
        // The framer is the whole reason this is Swift rather than another
        // throwaway Python splice: the bound T5 must carry is stated in frames,
        // and only the shipped framer decides where a frame ends.
        .package(path: "../../../../lib/DanTermProtocol"),
    ],
    targets: [
        .executableTarget(
            name: "T5Bridge",
            dependencies: [
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
