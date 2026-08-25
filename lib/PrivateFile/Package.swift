// swift-tools-version: 6.2
// Standalone package for the private-write seam: the one place either shipped product
// brings a file, a directory, or a Unix socket node into existence.
//
// It is its own package, and not a corner of DanTermSupport, because both products have
// to reach it. DanTermSupport is the Mac host's side-effect layer -- sockets, the
// CLI-path installer, CoreText -- and is pinned to macOS by design, so the iOS product
// could not depend on it without dragging that whole role in. A package that depends on
// nothing and declares both platforms is what lets one seam serve both, which is the
// invariant `scripts/private-file-mode-lint.sh` enforces.
import PackageDescription

let package = Package(
    name: "PrivateFile",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PrivateFile", targets: ["PrivateFile"]),
    ],
    targets: [
        .target(
            name: "PrivateFile",
            path: "Sources/PrivateFile",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PrivateFileTests",
            dependencies: ["PrivateFile"],
            path: "Tests/PrivateFileTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
