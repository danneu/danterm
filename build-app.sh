#!/usr/bin/env bash
#
# Canonical release build: SwiftPM compile + app bundle assembly.
# Called by CI and release workflows. Does NOT sign or notarize.
#
# Usage: ./build-app.sh [--version VERSION]
#   --version VERSION   Stamp CFBundleVersion and CFBundleShortVersionString
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Compile with SwiftPM (release mode, optimized)
echo "Compiling (release)..."
swift build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build" --configuration release
BIN_PATH=$(swift build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build" --configuration release --show-bin-path)

# The PTY session bootstrap is its own package and its own executable: the Swift
# terminal backend spawns it per session and reports itself not ready when the
# bundled copy is missing, so it must be built and bundled on the release path
# exactly as dev-build.sh does.
swift build --package-path "$SCRIPT_DIR/lib/TerminalPTY" \
    --build-path "$SCRIPT_DIR/.spm-build/TerminalPTY" \
    --configuration release --product PTYSessionBootstrap
BOOTSTRAP_BIN_PATH=$(swift build --package-path "$SCRIPT_DIR/lib/TerminalPTY" \
    --build-path "$SCRIPT_DIR/.spm-build/TerminalPTY" \
    --configuration release --show-bin-path)

APP_PATH="$SCRIPT_DIR/build/DanTerm.app"
LAYOUT_PLAN="$SCRIPT_DIR/.spm-build/bundle-layout-release.json"
mkdir -p "$(dirname "$LAYOUT_PLAN")"
"$BIN_PATH/DanTermBundleLayoutTool" release > "$LAYOUT_PLAN"
ASSEMBLE_ARGS=(
    "$APP_PATH" "$LAYOUT_PLAN" "$SCRIPT_DIR"
    --product "DanTerm=$BIN_PATH/DanTerm"
    --product "DanTermCLI=$BIN_PATH/DanTermCLI"
    --product "PTYSessionBootstrap=$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap"
)
if [[ -n "$VERSION" ]]; then
    ASSEMBLE_ARGS+=(--version "$VERSION")
fi
PATH="$PATH:$SCRIPT_DIR/scripts" assemble-app-bundle.sh "${ASSEMBLE_ARGS[@]}"
PATH="$PATH:$SCRIPT_DIR/scripts" verify-bundle-layout.sh \
    "$APP_PATH" "$LAYOUT_PLAN" "$SCRIPT_DIR"

echo "Built: $APP_PATH"
