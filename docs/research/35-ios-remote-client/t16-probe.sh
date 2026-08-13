#!/bin/bash
# Reproduction recipe for T16's two build results.
#
#   1. The candidate client module in t16-probe/ -- the client end of the control
#      conversation plus a pane-tape record reader -- builds for macOS and both iOS
#      triples with DanTermProtocol as its only dependency, and names nothing in
#      DanTermSupport. This is the evidence that the module a client links is a new
#      one rather than a half of DanTermSupport.
#
#   2. Once the F2 font seam is applied, a package-level iOS pin on lib/TerminalCore
#      is false for exactly two of its targets. The script builds every host-only
#      tooling target for the iOS device triple and prints pass/fail for each, so the
#      count is re-derived rather than asserted.
#
# Like ios-cross-compile.sh, the iOS platform pins and the font seam are applied to a
# scratch copy of each file and restored on exit or interrupt: they do not live in the
# tree until the work that makes them true has landed. Failed builds are the point of
# the run, so the exit status is 0 whenever the script itself completed. A patch that
# does not apply aborts instead, because a confusing failure is worse than no result.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# The default sits under .build-ios-* so .gitignore's existing rule covers it.
OUT="${1:-$ROOT/.build-ios-t16-logs}"
PROBE="$ROOT/docs/research/35-ios-remote-client/t16-probe"
PROTOCOL="$ROOT/lib/DanTermProtocol/Package.swift"
TC="$ROOT/lib/TerminalCore/Package.swift"
SEAM="$ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift"
mkdir -p "$OUT"

DEV_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEV_TRIPLE="arm64-apple-ios26.5"
SIM_TRIPLE="arm64-apple-ios26.5-simulator"

restore() {
  for f in "$PROTOCOL" "$TC" "$SEAM"; do
    [ -f "$f.t16-backup" ] && mv "$f.t16-backup" "$f"
  done
  return 0
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

# A leftover backup means an earlier run died where even the EXIT trap could not run,
# so the file on disk is the patched one. Copying over the backup would make the pins
# permanent and silent, which is the one outcome F1 rules out.
for f in "$PROTOCOL" "$TC" "$SEAM"; do
  if [ -f "$f.t16-backup" ]; then
    echo "$f.t16-backup exists: an earlier run left the tree patched." >&2
    echo "Restore it (mv it back) before rerunning." >&2
    exit 1
  fi
done

for f in "$PROTOCOL" "$TC"; do
  cp "$f" "$f.t16-backup"
  sed -i '' 's/platforms: \[\.macOS(\.v26)\]/platforms: [.macOS(.v26), .iOS(.v26)]/' "$f"
  if ! grep -q '\.iOS(\.v26)' "$f"; then
    echo "$f: the iOS pin did not apply; its platforms line no longer matches." >&2
    exit 1
  fi
done

cp "$SEAM" "$SEAM.t16-backup"
python3 - "$SEAM" <<'PATCH'
import sys
path = sys.argv[1]
text = open(path).read()
old_import = "import AppKit\n"
new_import = (
    "#if canImport(AppKit)\n"
    "import AppKit\n"
    "typealias PlatformFont = NSFont\n"
    "#else\n"
    "import UIKit\n"
    "typealias PlatformFont = UIFont\n"
    "#endif\n"
)
old_call = "NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)"
new_call = "PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)"
if old_import not in text or old_call not in text:
    sys.exit("TerminalRenderExecution.swift: the F2 seam patch no longer applies")
open(path, "w").write(text.replace(old_import, new_import, 1).replace(old_call, new_call, 1))
PATCH

build() { # label package target triple sdk
  local log="$OUT/$1.log"
  if swift build --package-path "$2" --build-path "$OUT/.build-$1" \
      ${3:+--target "$3"} ${4:+--triple "$4"} ${5:+--sdk "$5"} > "$log" 2>&1; then
    echo "PASS $1"
  else
    echo "FAIL $1 -- $(grep -oE 'error: .*' "$log" | sort -u | head -2 | tr '\n' ';')"
  fi
}

echo "== 1. the candidate client module =="
build client-macos "$PROBE" DanTermClient "" ""
build client-sim "$PROBE" DanTermClient "$SIM_TRIPLE" "$SIM_SDK"
build client-dev "$PROBE" DanTermClient "$DEV_TRIPLE" "$DEV_SDK"

echo "== 2. the font seam, so TerminalRenderExecution is not the answer below =="
build render-macos "$ROOT/lib/TerminalCore" TerminalRenderExecution "" ""
build render-sim "$ROOT/lib/TerminalCore" TerminalRenderExecution "$SIM_TRIPLE" "$SIM_SDK"
build render-dev "$ROOT/lib/TerminalCore" TerminalRenderExecution "$DEV_TRIPLE" "$DEV_SDK"

echo "== 3. what a package-level iOS pin on lib/TerminalCore would falsely claim =="
TOOLING=(
  GlyphPreview TerminalDrawBenchmarkSupport TerminalDrawBenchmark
  TerminalCoreBenchmarkSupport TerminalCoreBenchmark
  TerminalMemoryProbeSupport TerminalMemoryProbe
  TerminalOccupancyProbeSupport TerminalOccupancyProbe
  TerminalResizeProbeSupport TerminalResizeProbe
  TerminalRetainedRowProbeSupport TerminalRetainedRowProbe
  TerminalBrowseBenchmarkSupport TerminalBrowseBenchmark
  TerminalBenchmarkMarkers TerminalBenchmarkTopology TerminalBenchmarkCoverage
)
for t in "${TOOLING[@]}"; do
  build "tc-$t" "$ROOT/lib/TerminalCore" "$t" "$DEV_TRIPLE" "$DEV_SDK"
done
