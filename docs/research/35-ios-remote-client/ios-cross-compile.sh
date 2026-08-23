#!/bin/bash
# Reproduction recipe for F1: build each candidate portable module of lib/ for an
# iOS simulator triple and an iOS device triple, and print pass/fail per module.
#
# The iOS platform pins do not live in the tree (see F1 -- a package-level pin
# would claim iOS support for host-only targets in the same package), so this
# script adds them to a scratch copy of each manifest, builds, and restores the
# manifest when it exits or is interrupted. It finds the repository from its own
# path, so it runs from any directory. Build products and default logs share the
# research descendant of the repository's disposable gate root.
#
# Failed builds are the point of the run, not an error, so the exit status is 0
# whenever the script itself completed. A build that failed for an uninteresting
# reason -- a pin that did not apply, a manifest left patched by an earlier run --
# aborts instead, because a confusing failure is worse than no result.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/scripts/lib/build-paths.sh"
RESEARCH_ROOT="$(danterm_gate_build_path "$ROOT" research/ios-remote-client/cross-compile)"
OUT="${1:-$RESEARCH_ROOT/logs}"
mkdir -p "$OUT"

SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEV_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_TRIPLE="arm64-apple-ios26.5-simulator"
DEV_TRIPLE="arm64-apple-ios26.5"

PACKAGES=(TerminalCore DanTermProtocol DanTermCore DanTermSupport)

# module:package -- the set T1 declared portable, plus TerminalCoreRecording
# (the tape stream the client consumes) and TerminalRenderExecution (T2's
# subject, built here only to record where it stops).
MODULES=(
  "TerminalCore:TerminalCore"
  "TerminalCoreRecording:TerminalCore"
  "TerminalSpriteGeometry:TerminalCore"
  "TerminalRenderPlanning:TerminalCore"
  "TerminalRenderExecution:TerminalCore"
  "DanTermProtocol:DanTermProtocol"
  "DanTermCore:DanTermCore"
  "DanTermSupport:DanTermSupport"
)

restore_manifests() {
  for pkg in "${PACKAGES[@]}"; do
    if [ -f "$ROOT/lib/$pkg/Package.swift.t1-backup" ]; then
      mv "$ROOT/lib/$pkg/Package.swift.t1-backup" "$ROOT/lib/$pkg/Package.swift"
    fi
  done
}
trap restore_manifests EXIT
# Without this, Ctrl-C only kills the running `swift build`; the loop keeps going
# and the manifests stay patched for the rest of the run.
trap 'restore_manifests; exit 130' INT TERM

# A leftover backup means an earlier run died where even the EXIT trap could not
# run, so the manifest on disk is the patched one. Copying over the backup here
# would make the pins permanent and silent, which is the one outcome F1 rules out.
for pkg in "${PACKAGES[@]}"; do
  if [ -f "$ROOT/lib/$pkg/Package.swift.t1-backup" ]; then
    echo "lib/$pkg/Package.swift.t1-backup exists: an earlier run left the tree" >&2
    echo "patched. Restore it (mv it back over Package.swift) before rerunning." >&2
    exit 1
  fi
done

for pkg in "${PACKAGES[@]}"; do
  cp "$ROOT/lib/$pkg/Package.swift" "$ROOT/lib/$pkg/Package.swift.t1-backup"
  sed -i '' 's/platforms: \[\.macOS(\.v26)\]/platforms: [.macOS(.v26), .iOS(.v26)]/' \
    "$ROOT/lib/$pkg/Package.swift"
  if ! grep -q '\.iOS(\.v26)' "$ROOT/lib/$pkg/Package.swift"; then
    echo "lib/$pkg/Package.swift: the iOS pin did not apply; its platforms line" >&2
    echo "no longer matches the pattern this script patches." >&2
    exit 1
  fi
done

build() { # module package triple sdk tag
  local module="$1" pkg="$2" triple="$3" sdk="$4" tag="$5"
  local log="$OUT/$module-$tag.log"
  # --target, not --product: SwiftPM ignores --product for an automatic library
  # product and builds every target in the package instead. Per-package build
  # paths for the same reason -- one shared path across packages reuses the
  # wrong build description.
  if swift build --package-path "$ROOT/lib/$pkg" \
      --build-path "$RESEARCH_ROOT/swiftpm/$tag-$pkg" \
      --target "$module" \
      --triple "$triple" --sdk "$sdk" > "$log" 2>&1; then
    echo "PASS $module $tag"
  else
    echo "FAIL $module $tag ($log)"
  fi
}

for row in "${MODULES[@]}"; do
  module="${row%%:*}"
  pkg="${row##*:}"
  build "$module" "$pkg" "$SIM_TRIPLE" "$SIM_SDK" sim
  build "$module" "$pkg" "$DEV_TRIPLE" "$DEV_SDK" dev
done

# The second half of F1's DanTermSupport result: the module builds once the two
# host-only files leave it, which is what makes the failure a file split rather
# than a port. Exclusion here is a probe, not a proposed fix -- T16 owns the fix.
sed -i '' \
  's|path: "Sources/DanTermSupport",|path: "Sources/DanTermSupport",\n            exclude: ["CLIPathInstaller.swift", "DoctorProber.swift"],|' \
  "$ROOT/lib/DanTermSupport/Package.swift"
if ! grep -q 'CLIPathInstaller.swift' "$ROOT/lib/DanTermSupport/Package.swift"; then
  echo "lib/DanTermSupport/Package.swift: the exclude probe did not apply." >&2
  exit 1
fi
build DanTermSupport DanTermSupport "$SIM_TRIPLE" "$SIM_SDK" sim-minus-host-files
build DanTermSupport DanTermSupport "$DEV_TRIPLE" "$DEV_SDK" dev-minus-host-files
