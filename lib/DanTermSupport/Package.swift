// swift-tools-version: 6.2
// Standalone test package for DanTerm's portable side-effect layer (DanTermSupport):
// sockets, timers, the CLI-path installer, and the recovery store. Mirrors the
// DanTermCore nested-package + symlink mechanism -- the SAME files in
// Sources/DanTermSupport/ compile into the app's `DanTerm` target via the tracked
// `app/DanTermSupport` symlink (plain `internal`, no access annotations) and ALSO
// compile here as a separate module that DanTermSupportTests reach via
// `@testable import DanTermSupport`. Running `swift test` here builds only
// DanTermSupport + its tests -- no AppKit, and NO dependency on
// DanTermCore. That sibling-independence is the structural proof that keeps the
// whole split annotation-free. See docs/design/2026-05-28-core-module-via-symlink.md
// and plans/impl/2026-05-29-pure-core-portable-support.md.
import PackageDescription

let package = Package(
    name: "DanTermSupport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DanTermSupport", targets: ["DanTermSupport"])],
    dependencies: [
        // Sibling package dep (NOT a target `path:` -- SwiftPM forbids a source path
        // escaping the package root via `..`). IpcConnection (Phase 3) consumes the
        // framer that moves to DanTermProtocol in Phase 2; declared now so the
        // manifest is stable. Support depends on NOTHING in DanTermCore.
        .package(path: "../DanTermProtocol"),
    ],
    targets: [
        .target(
            name: "DanTermSupport",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "Sources/DanTermSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DanTermSupportTests",
            dependencies: [
                "DanTermSupport",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "Tests/DanTermSupportTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
