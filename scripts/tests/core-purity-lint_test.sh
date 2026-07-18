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
#   3. the portable profile's GhosttyKit rule plus its deliberate tolerance of
#      portable IO (FileManager/DispatchSource/ProcessInfo are fine in support);
#   4. the opt-in import gate rejects every library-target import while allowing
#      import-free Swift source.
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
# portable profile -- GhosttyKit + Cocoa banned; portable IO deliberately allowed.
# ---------------------------------------------------------------------------
assert_lint portable trip "port: import GhosttyKit"    "import GhosttyKit"
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

echo "core-purity lint self-test passed ($TOTAL assertions across pure + portable profiles and import gate)"
