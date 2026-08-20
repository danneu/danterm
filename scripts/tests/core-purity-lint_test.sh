#!/usr/bin/env bash
# Self-test for scripts/core-purity-lint.sh. Each fixture declares a profile, an
# expectation (trip = exit 1, pass = exit 0), and a one-line Swift source; the
# harness writes it to a temp module and asserts the lint behaves. A silent regex
# regression in the lint must itself be caught here. Guards, in order:
#
#   1. the original Cocoa/AppKit/SwiftUI import rule (still both profiles);
#   2. the pure profile's IO/nondeterminism denylist:
#        - hard bans (FileManager, Process(, DispatchSource, ProcessInfo, import
#          Darwin/Network, ...) trip with NO allowlist;
#        - the NSHomeDirectory / bare UUID() / bare Date() ambient-seam allowlist
#          passes ONLY with the `// core-purity: ambient-seam` marker on the RAW
#          line, and the marker NEVER exempts a hard-ban on the same line;
#        - comment/string stripping keeps pure comments and the deterministic
#          UUID(uuidString:) / Date(timeIntervalSince1970:) parses from tripping;
#   3. the portable profile's Cocoa rule plus its deliberate tolerance of
#      portable IO (FileManager/DispatchSource/ProcessInfo are fine in support);
#   4. the opt-in import gates either reject every library-target import or
#      allow exactly the named modules while rejecting every other real import.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../core-purity-lint.sh"
MARKER="// core-purity: ambient-seam"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOTAL=0

fail() { echo "FAIL: $1" >&2; exit 1; }

# assert_lint <profile> <trip|pass> <description> <source-line>
assert_lint() {
    local profile="$1" expect="$2" desc="$3" line="$4"
    local dir="$TMP/case"
    rm -rf "$dir"; mkdir -p "$dir"
    printf '%s\n' "$line" > "$dir/Module.swift"
    local got
    if "$LINT" --profile "$profile" "$dir" >/dev/null 2>&1; then got="pass"; else got="trip"; fi
    [[ "$got" == "$expect" ]] || fail "[$profile] expected '$expect' got '$got' :: $desc :: <$line>"
    TOTAL=$((TOTAL + 1))
}

# assert_import_gate <trip|pass> <description> <source-line>
assert_import_gate() {
    local expect="$1" desc="$2" line="$3"
    local dir="$TMP/import-case"
    rm -rf "$dir"; mkdir -p "$dir"
    printf '%s\n' "$line" > "$dir/Module.swift"
    local got
    if "$LINT" --forbid-imports "$dir" >/dev/null 2>&1; then got="pass"; else got="trip"; fi
    [[ "$got" == "$expect" ]] || fail "[import gate] expected '$expect' got '$got' :: $desc :: <$line>"
    TOTAL=$((TOTAL + 1))
}

# assert_import_allowlist <allowed-modules> <trip|pass> <description> <source-line>
assert_import_allowlist() {
    local allowed="$1" expect="$2" desc="$3" line="$4"
    local dir="$TMP/import-allowlist-case"
    rm -rf "$dir"; mkdir -p "$dir"
    printf '%s\n' "$line" > "$dir/Module.swift"
    local got
    if "$LINT" --allow-imports "$allowed" "$dir" >/dev/null 2>&1; then got="pass"; else got="trip"; fi
    [[ "$got" == "$expect" ]] || fail "[import allowlist] expected '$expect' got '$got' :: $desc :: <$line>"
    TOTAL=$((TOTAL + 1))
}

# ---------------------------------------------------------------------------
# pure profile -- Cocoa/AppKit/SwiftUI import rule (preserved from the original).
# ---------------------------------------------------------------------------
assert_lint pure trip "cocoa: import Cocoa"            "import Cocoa"
assert_lint pure trip "cocoa: @preconcurrency AppKit"  "@preconcurrency import AppKit"
assert_lint pure trip "cocoa: leading-ws SwiftUI"      "  import SwiftUI"
assert_lint pure trip "cocoa: @_exported Cocoa"        "@_exported import Cocoa"
assert_lint pure trip "cocoa: @_spi AppKit"            "@_spi(Foo) import AppKit"

assert_lint pure pass "cocoa neg: Foundation"          "import Foundation"
assert_lint pure pass "cocoa neg: CocoaLumberjack"     "import CocoaLumberjack"
assert_lint pure pass "cocoa neg: CocoaAsyncSocket"    "import CocoaAsyncSocket"
assert_lint pure pass "cocoa neg: commented AppKit"    "// import AppKit"
assert_lint pure pass "cocoa neg: SwiftUIPlus"         "import SwiftUIPlus"
assert_lint pure pass "cocoa neg: AppKitExtensions"    "import AppKitExtensions"
assert_lint pure pass "cocoa neg: trailing comment"    "let x = 42 // import Cocoa in a comment"

# ---------------------------------------------------------------------------
# pure profile -- hard-ban tier (no allowlist; these utilities leave the core).
# ---------------------------------------------------------------------------
assert_lint pure trip "hard: import Darwin"            "import Darwin"
assert_lint pure trip "hard: import Darwin.C submod"   "import Darwin.C"
assert_lint pure trip "hard: import Network"           "import Network"
assert_lint pure trip "hard: FileManager"              "        guard let d = FileManager.default.contents(atPath: p) else { return }"
assert_lint pure trip "hard: DispatchSource timer"     "        let t = DispatchSource.makeTimerSource(queue: q)"
assert_lint pure trip "hard: DispatchQueue("           "        let q = DispatchQueue(label: name)"
assert_lint pure trip "hard: .asyncAfter"              "        q.asyncAfter(deadline: .now()) {}"
assert_lint pure trip "hard: Process("                 "        let p = Process()"
assert_lint pure trip "hard: Timer("                   "        let t = Timer(timeInterval: 1, repeats: false) { _ in }"
assert_lint pure trip "hard: URLSession"               "        let s = URLSession.shared"
assert_lint pure trip "hard: NSWorkspace"              "        NSWorkspace.shared.open(url)"
assert_lint pure trip "hard: setsockopt"               "        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &v, len)"
assert_lint pure trip "hard: Data(contentsOf:"         "        let d = try Data(contentsOf: url)"
assert_lint pure trip "hard: .write(to:"               "        try data.write(to: url)"
assert_lint pure trip "hard: ProcessInfo"              "        let pid = ProcessInfo.processInfo.processIdentifier"

# ---------------------------------------------------------------------------
# pure profile -- ambient-seam tier: UNMARKED tokens trip.
# ---------------------------------------------------------------------------
assert_lint pure trip "seam: unmarked NSHomeDirectory" "        let home = NSHomeDirectory()"
assert_lint pure trip "seam: unmarked bare UUID()"     "        let id = PaneId(rawValue: UUID())"
assert_lint pure trip "seam: unmarked bare Date()"     "        let now = Date()"

# ---------------------------------------------------------------------------
# pure profile -- ambient-seam tier: the marker (on the RAW line) relaxes the
# three allowlisted tokens. This is the comment-strip-vs-marker landmine: tokens
# are detected on the comment-stripped line, but the marker must be read on the
# raw line, or stripping erases it and every seam trips.
# ---------------------------------------------------------------------------
assert_lint pure pass "seam: marked NSHomeDirectory"   "        homeDirectory: { NSHomeDirectory() }  $MARKER"
assert_lint pure pass "seam: marked UUID()"            "        newId: { UUID() },  $MARKER"
assert_lint pure pass "seam: marked Date()"            "        now: { Date() },  $MARKER"
assert_lint pure pass "seam: marked leaf default"      "func abbreviateHome(_ p: String, home: String = NSHomeDirectory()) -> String {  $MARKER"
# ...but the marker must NOT blanket-exempt a hard-ban token on the same line.
assert_lint pure trip "seam: marker !exempt hard-ban"  "        let d = FileManager.default  $MARKER"

# ---------------------------------------------------------------------------
# pure profile -- negatives that must PASS (comment/string stripping + the
# empty-parens specificity of the UUID()/Date() bans).
# ---------------------------------------------------------------------------
assert_lint pure pass "neg: UUID(uuidString:)"         "        guard let u = UUID(uuidString: s) else { return nil }"
assert_lint pure pass "neg: Date(timeIntervalSince..)" "        let d = Date(timeIntervalSince1970: 0)"
assert_lint pure pass "neg: tokens in // comment"      "        // the DispatchSourceTimer glue; FileManager/Data; bare UUID() and Date()"
assert_lint pure pass "neg: tokens in /// doc comment" "    /// reads NSHomeDirectory() via .live or a leaf default"
assert_lint pure pass "neg: ProcessInfo in a comment"  "        // the pid is sourced from ProcessInfo over in support"
assert_lint pure pass "neg: token inside a string"     "        let label = \"FileManager and NSHomeDirectory() are fine in a string\""
assert_lint pure pass "neg: tokens in /* */ block"     "        let x = 1 /* FileManager DispatchSource ProcessInfo */ + 2"
assert_lint pure pass "neg: plain Foundation import"   "import Foundation"

# ---------------------------------------------------------------------------
# portable profile -- Cocoa banned; portable IO deliberately allowed.
# ---------------------------------------------------------------------------
assert_lint portable trip "port: import AppKit"        "import AppKit"
assert_lint portable pass "port: FileManager ok"       "        let d = FileManager.default.contents(atPath: p)"
assert_lint portable pass "port: DispatchSource ok"    "        let t = DispatchSource.makeTimerSource(queue: q)"
assert_lint portable pass "port: ProcessInfo ok"       "        let pid = ProcessInfo.processInfo.processIdentifier"
assert_lint portable pass "port: Process( ok"          "        let p = Process()"
assert_lint portable pass "port: import Foundation"    "import Foundation"

# ---------------------------------------------------------------------------
# import-free library gate -- any real import trips; ordinary source passes.
# ---------------------------------------------------------------------------
assert_import_gate trip "Foundation is still an import" "import Foundation"
assert_import_gate trip "Testing is still an import"    "import Testing"
assert_import_gate trip "attributed import"             "@_implementationOnly import Foundation"
assert_import_gate trip "access-level import"            "public import Foundation"
assert_import_gate trip "stacked import modifiers"       "@preconcurrency public import Foundation"
assert_import_gate pass "import-free declaration"       "struct Cell { let value: UInt32 }"
assert_import_gate pass "commented import"              "// import Foundation"

# ---------------------------------------------------------------------------
# import-allowlist library gate -- named modules pass; every other real import
# trips, including a submodule of an allowed module.
# ---------------------------------------------------------------------------
assert_import_allowlist TerminalCore pass "allowed module"                 "import TerminalCore"
assert_import_allowlist TerminalCore pass "allowed attributed import"      "@_implementationOnly import TerminalCore"
assert_import_allowlist TerminalCore pass "import-free declaration"        "struct RenderPlan {}"
assert_import_allowlist TerminalCore pass "commented disallowed import"     "// import Foundation"
assert_import_allowlist TerminalCore trip "Foundation is not allowed"       "import Foundation"
assert_import_allowlist TerminalCore trip "allowed module subpath is exact" "import TerminalCore.Internal"
assert_import_allowlist TerminalCore,Testing pass "multiple allowed modules" "import Testing"
assert_import_allowlist TerminalCore,Testing trip "module outside list"      "import AppKit"

# ---------------------------------------------------------------------------
# sweep mode -- the whole-tree pass the gate runs as one step.
#
# The property that matters here is coverage, not any single rule: a module the
# policy file never names must still be checked, at the portable floor. Before
# the sweep existed the gate named eleven targets by hand and the tree had
# thirty-five modules, so twenty-seven were unchecked and nothing said so.
#
# Each case builds a throwaway tree of module directories plus a policy file and
# points the sweep at both, so a verdict is proven without touching the real tree.
# ---------------------------------------------------------------------------

# sweep_module <module-path-under-root> <source-line>
sweep_module() {
    local dir="$SWEEP_ROOT/$1"
    local package="${1%%/Sources/*}"
    mkdir -p "$dir"
    printf '%s\n' '// swift-tools-version: 6.2' > "$SWEEP_ROOT/$package/Package.swift"
    printf '%s\n' "$2" > "$dir/Module.swift"
}

sweep_reset() {
    SWEEP_ROOT="$TMP/sweep-root"
    SWEEP_POLICY="$TMP/sweep-policy.conf"
    rm -rf "$SWEEP_ROOT"; mkdir -p "$SWEEP_ROOT"
    git init -q "$SWEEP_ROOT"
    : > "$SWEEP_POLICY"
}

# assert_sweep <trip|pass> <description>
assert_sweep() {
    local expect="$1" desc="$2" got
    if [[ "${TRACK_SWEEP:-1}" == 1 ]]; then
        git -C "$SWEEP_ROOT" add -A
    fi
    if CORE_PURITY_LINT_ROOT="$SWEEP_ROOT" CORE_PURITY_LINT_POLICY="$SWEEP_POLICY" \
        "$LINT" >/dev/null 2>&1; then got="pass"; else got="trip"; fi
    [[ "$got" == "$expect" ]] || fail "[sweep] expected '$expect' got '$got' :: $desc"
    TOTAL=$((TOTAL + 1))
}

# An undeclared module is not an unchecked module: it gets the portable floor,
# which bans platform UI and tolerates portable IO.
sweep_reset
sweep_module lib/Pkg/Sources/Undeclared "import AppKit"
assert_sweep trip "undeclared module still gets the UI ban"

sweep_reset
sweep_module lib/Pkg/Sources/Undeclared "        let d = FileManager.default"
assert_sweep pass "the floor is portable, so portable IO is fine"

sweep_reset
sweep_module lib/Pkg/Sources/Strict "        let d = FileManager.default"
printf 'lib/Pkg/Sources/Strict pure\n' > "$SWEEP_POLICY"
assert_sweep trip "a module declared pure gets the IO denylist"

sweep_reset
sweep_module lib/Pkg/Sources/Strict "import DequeModule"
printf 'lib/Pkg/Sources/Strict pure allow=DequeModule\n' > "$SWEEP_POLICY"
assert_sweep pass "a pure module carries its import allowlist"

sweep_reset
sweep_module lib/Pkg/Sources/Strict "import Foundation"
printf 'lib/Pkg/Sources/Strict pure forbid-imports\n' > "$SWEEP_POLICY"
assert_sweep trip "a pure module carries its import-free rule"

sweep_reset
sweep_module lib/Pkg/Sources/Chrome "import AppKit"
printf 'lib/Pkg/Sources/Chrome ui\n' > "$SWEEP_POLICY"
assert_sweep pass "a declared ui module is exempt from the UI ban"

# A policy line outliving the module it names is the failure the hand-written
# step list used to hide: the entry reads as coverage while checking nothing.
sweep_reset
sweep_module lib/Pkg/Sources/Present "struct Cell {}"
printf 'lib/Pkg/Sources/Renamed ui\n' > "$SWEEP_POLICY"
assert_sweep trip "a policy entry naming no module fails"

sweep_reset
sweep_module lib/Pkg/Sources/Mystery "struct Cell {}"
printf 'lib/Pkg/Sources/Mystery quarantined\n' > "$SWEEP_POLICY"
assert_sweep trip "an unknown policy word fails rather than being ignored"

sweep_reset
sweep_module lib/Pkg/Sources/Clean "struct Cell {}"
sweep_module ios/App/Sources/MobileClean "import Foundation"
assert_sweep pass "a clean tree passes, iOS modules included"

# A package outside the historical roots is still swept.
sweep_reset
sweep_module tools/Tool/Sources/Tool "import AppKit"
assert_sweep trip "a tracked package outside lib and ios is swept"

# Excluded and untracked package trees never enter the sweep.
sweep_reset
sweep_module tools/Tool/Sources/Tool "struct Tool {}"
sweep_module docs/Spike/Sources/DocsOnly "import AppKit"
git -C "$SWEEP_ROOT" add -A
sweep_module scratch/Untracked/Sources/Untracked "import AppKit"
TRACK_SWEEP=0 assert_sweep pass "excluded and untracked manifests stay outside the sweep"

# A repository with no discovered first-party manifest fails instead of sweeping zero modules.
sweep_reset
sweep_module docs/Spike/Sources/DocsOnly "struct DocsOnly {}"
git -C "$SWEEP_ROOT" add -A
TRACK_SWEEP=0 assert_sweep trip "an empty first-party discovery fails"

echo "core-purity lint self-test passed ($TOTAL assertions across pure + portable profiles, import gates, and the sweep)"
