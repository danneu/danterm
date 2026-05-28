// swift-tools-version: 6.2
// Standalone test package for DanTerm's pure model/update core.
//
// The SAME `.swift` files in Sources/DanTermCore/ are compiled two independent
// ways: the root app build picks them up as part of the `app/` target via the
// tracked `app/DanTermCore` symlink (so the core stays in the app's own module --
// plain `internal`, no access annotations -- per plan R1), and THIS package
// compiles them as a separate GhosttyKit-free `DanTermCore` module that the
// Swift Testing suites reach via `@testable import DanTermCore`. Running
// `swift test` here builds only DanTermCore + DanTermCoreTests -- not the
// GhosttyKit-linked app -- which is the whole reason for a nested package (see
// plan "Why a nested package").
//
// The symlink replaces the plan's `path: "."` design after Phase 0 found that
// `path: "."` is incompatible with the project's `--build-path .spm-build` build
// scripts (every incremental rebuild fails with "unknown build description").
// `path: "app"` + symlink keeps R1 same-module + `--build-path` + zero exclude-list
// growth. See docs/design/<date>-danterm-core-symlink.md (added at Phase 3 cutover).
//
// Isolation enforced by this package: a core file that gains an app-only symbol
// or `import GhosttyKit` fails to resolve here (neither is a dependency).
// Cocoa-freeness is enforced separately by a local lint -- system frameworks
// link by default in any macOS SwiftPM target.
import PackageDescription

let package = Package(
    name: "DanTermCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DanTermCore", targets: ["DanTermCore"])],
    dependencies: [
        // DanTermProtocol comes in as a sibling package dependency, NOT a target
        // `path:` -- SwiftPM forbids a target's source path escaping the package
        // root via `..`.
        .package(path: "../DanTermProtocol"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DanTermCore",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "Sources/DanTermCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DanTermCoreTests",
            dependencies: [
                "DanTermCore",
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/DanTermCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
