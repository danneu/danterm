// swift-tools-version: 6.2
// A throwaway probe for T16, not a proposed manifest: does the module an iOS client
// actually links -- the client end of the control-socket conversation, plus a reader
// for the pane-tape record shape -- compile for both iOS triples with DanTermProtocol
// as its only dependency, and without referencing DanTermSupport?
//
// The sibling dependency needs an iOS platform pin, which does not live in the tree
// (see F1). t16-probe.sh applies and restores it; building this package directly will
// fail until the pin is present.
import PackageDescription

let package = Package(
    name: "DanTermClient",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "DanTermClient", targets: ["DanTermClient"])],
    dependencies: [.package(path: "../../../../lib/DanTermProtocol")],
    targets: [
        .target(
            name: "DanTermClient",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "Sources/DanTermClient",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
