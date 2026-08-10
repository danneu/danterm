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

# Assemble app bundle
APP_PATH="$SCRIPT_DIR/build/DanTerm.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm"
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
chmod +x "$APP_PATH/Contents/Helpers/danterm"
cp "$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap" "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"
chmod +x "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"

# Defense in depth. A case-insensitive filesystem can collapse paths
# that differ only by case, and a copy-source mistake can write the CLI
# bytes into both files. Either produces a signed bundle that will not launch.
GUI="$APP_PATH/Contents/MacOS/DanTerm"
CLI="$APP_PATH/Contents/Helpers/danterm"
# /usr/bin/stat, not stat: a nix profile earlier on PATH shadows it with GNU
# coreutils, where -f asks for filesystem info and this guard aborts the build.
GUI_INODE=$(/usr/bin/stat -f %i "$GUI")
CLI_INODE=$(/usr/bin/stat -f %i "$CLI")
if [ "$GUI_INODE" = "$CLI_INODE" ]; then
    echo "Error: GUI and CLI bundle paths collided (same inode)" >&2
    exit 1
fi
if cmp -s "$GUI" "$CLI"; then
    echo "Error: GUI and CLI bundle binaries have identical content" >&2
    exit 1
fi

cp "$SCRIPT_DIR/app/Info.plist" "$APP_PATH/Contents/"

if [ -n "$VERSION" ]; then
    plutil -replace CFBundleVersion -string "$VERSION" "$APP_PATH/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Contents/Info.plist"
fi

mkdir -p "$APP_PATH/Contents/Resources"
cp "$SCRIPT_DIR/icon/AppIcon/Assets.car" "$APP_PATH/Contents/Resources/"
mkdir -p "$APP_PATH/Contents/Resources/danterm"
cp "$SCRIPT_DIR/integrations/danterm/SKILL.md" \
    "$APP_PATH/Contents/Resources/danterm/SKILL.md"
cmp "$SCRIPT_DIR/integrations/danterm/SKILL.md" \
    "$APP_PATH/Contents/Resources/danterm/SKILL.md"

# Bundle the agent hook scripts as plain resources so users can point Claude Code
# and Codex hooks at a stable in-bundle path. These must live under Resources,
# not Helpers: executable non-Mach-O files in nested-code locations lose their
# signature across the published ZIP round-trip, while Resources are sealed by
# content. The basenames match the Nix packages, but these are the raw scripts
# and still need jq, plus danterm for the session hooks, on PATH at runtime.
mkdir -p "$APP_PATH/Contents/Resources/danterm-hooks"
for pair in \
    "integrations/claude-code/claude-notify-osc777.sh danterm-claude-notify-osc777" \
    "integrations/claude-code/danterm-agent-session.sh danterm-claude-agent-session" \
    "integrations/codex/danterm-agent-session.sh danterm-codex-agent-session"; do
    # Intentional word splitting: each entry is a "source destination" pair.
    # shellcheck disable=SC2086
    set -- $pair
    cp "$SCRIPT_DIR/$1" "$APP_PATH/Contents/Resources/danterm-hooks/$2"
    chmod +x "$APP_PATH/Contents/Resources/danterm-hooks/$2"
    test -x "$APP_PATH/Contents/Resources/danterm-hooks/$2" || { echo "Error: hook script $2 not bundled" >&2; exit 1; }
done

# Ship the integration tree wholesale, not just the three entry points:
# danterm.bash sources vendor/bash-preexec.sh relative to its own BASH_SOURCE,
# so a bundle missing vendor/ breaks on the very line the README tells bash
# users to source. The explicit asset check mirrors the danterm-hooks guard
# above -- a silently thinned copy must fail the build, not the user's shell.
rm -rf "$APP_PATH/Contents/Resources/shell-integration"
cp -R "$SCRIPT_DIR/integrations/shell-integration" \
    "$APP_PATH/Contents/Resources/shell-integration"
for asset in danterm.zsh danterm.bash danterm.fish \
    vendor/bash-preexec.sh vendor/bash-preexec.LICENSE vendor/bash-preexec.PROVENANCE; do
    test -r "$APP_PATH/Contents/Resources/shell-integration/$asset" \
        || { echo "Error: shell integration asset $asset not bundled" >&2; exit 1; }
done

"$SCRIPT_DIR/scripts/bundle-theme-resources.sh" "$SCRIPT_DIR" "$APP_PATH"

echo "Built: $APP_PATH"
