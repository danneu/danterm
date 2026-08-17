// swift-tools-version: 6.2
// Standalone test package for DanTerm's pure model/update core.
//
// The SAME `.swift` files in Sources/DanTermCore/ are compiled two independent
// ways: the root app build picks them up as part of the `app/` target via the
// tracked `app/DanTermCore` symlink (so the core stays in the app's own module --
// plain `internal`, no access annotations -- per plan R1), and THIS package
// compiles them as a separate `DanTermCore` module that the
// Swift Testing suites reach via `@testable import DanTermCore`. Running
// `swift test` here builds only DanTermCore + DanTermCoreTests -- not the
// AppKit app -- which is the whole reason for a nested package (see
// plan "Why a nested package").
//
// The symlink replaces the plan's `path: "."` design after Phase 0 found that
// `path: "."` is incompatible with the project's `--build-path .spm-build` build
// scripts (every incremental rebuild fails with "unknown build description").
// `path: "app"` + symlink keeps R1 same-module + `--build-path` + zero exclude-list
// growth. See docs/design/<date>-danterm-core-symlink.md (added at Phase 3 cutover).
//
// Isolation enforced by this package: a core file that gains an app-only symbol
// fails to resolve here (it is not a dependency).
// Purity (no IO, no ambient nondeterminism) is enforced separately by a local
// lint (scripts/core-purity-lint.sh, pure profile) -- the compiler enforces none
// of it, since system frameworks link by default in any macOS SwiftPM target and
// Foundation/Darwin IO compiles anywhere. The sibling DanTermSupport package
// mirrors this symlink + nested-package pattern for the portable side effects the
// core sheds (its lint runs the portable profile).
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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DanTermCoreTests",
            dependencies: [
                "DanTermCore",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/DanTermCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
