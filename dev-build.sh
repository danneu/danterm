#!/usr/bin/env bash
#
# Build DanTerm Dev locally without nix.
#
set -euo pipefail

SWIFT_CONFIGURATION=""
KILL_RUNNING=""
INSTALL="1"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) SWIFT_CONFIGURATION="release" ;;
        --kill-running) KILL_RUNNING="1" ;;
        --no-install) INSTALL="" ;;
        *)
            echo "Usage: $0 [--release] [--kill-running] [--no-install]" >&2
            exit 2
            ;;
    esac
    shift
done

if [ -n "$KILL_RUNNING" ] && [ -z "$INSTALL" ]; then
    echo "Error: --kill-running cannot be combined with --no-install" >&2
    exit 2
fi

swift_build() {
    if [ -n "$SWIFT_CONFIGURATION" ]; then
        swift build "$@" --configuration "$SWIFT_CONFIGURATION"
    else
        swift build "$@"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_PATH="$BUILD_DIR/DanTerm Dev.app"
INSTALL_APP="$HOME/Applications/DanTerm Dev.app"
LSREGISTER="${DANTERM_DEV_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"
SRC_DIR="$SCRIPT_DIR/app"
LIB_DIR="$SCRIPT_DIR/lib"

# Build with SwiftPM (incremental — only recompiles changed files).
echo "Compiling..."
swift_build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build"
BIN_PATH=$(swift_build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build" \
    --show-bin-path)
swift_build \
    --package-path "$LIB_DIR/TerminalPTY" \
    --build-path "$SCRIPT_DIR/.spm-build/TerminalPTY" \
    --product PTYSessionBootstrap
BOOTSTRAP_BIN_PATH=$(swift_build \
    --package-path "$LIB_DIR/TerminalPTY" \
    --build-path "$SCRIPT_DIR/.spm-build/TerminalPTY" \
    --show-bin-path)

# Build app bundle
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm Dev"
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
chmod +x "$APP_PATH/Contents/Helpers/danterm"
cp "$BIN_PATH/DanTermInstanceIdentityTool" "$APP_PATH/Contents/Helpers/danterm-instance-identity"
chmod +x "$APP_PATH/Contents/Helpers/danterm-instance-identity"
cp "$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap" "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"
chmod +x "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"

cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$SCRIPT_DIR/icon/AppIcon-dev/Assets.car" "$APP_PATH/Contents/Resources/"
mkdir -p "$APP_PATH/Contents/Resources/danterm"
cp "$SCRIPT_DIR/integrations/danterm/SKILL.md" \
    "$APP_PATH/Contents/Resources/danterm/SKILL.md"
cmp "$SCRIPT_DIR/integrations/danterm/SKILL.md" \
    "$APP_PATH/Contents/Resources/danterm/SKILL.md"

# Bundle agent hook scripts under Resources, matching release builds. These are
# raw scripts, so jq and, for session hooks, danterm must be on PATH at runtime.
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

# Ship the whole integration tree, matching release builds: danterm.bash sources
# vendor/bash-preexec.sh as a sibling of itself, so a bundle missing vendor/
# breaks the documented bash source line.
rm -rf "$APP_PATH/Contents/Resources/shell-integration"
cp -R "$SCRIPT_DIR/integrations/shell-integration" \
    "$APP_PATH/Contents/Resources/shell-integration"
for asset in danterm.zsh danterm.bash danterm.fish \
    vendor/bash-preexec.sh vendor/bash-preexec.LICENSE vendor/bash-preexec.PROVENANCE; do
    test -r "$APP_PATH/Contents/Resources/shell-integration/$asset" \
        || { echo "Error: shell integration asset $asset not bundled" >&2; exit 1; }
done

"$SCRIPT_DIR/scripts/bundle-theme-resources.sh" "$SCRIPT_DIR" "$APP_PATH"

# Patch Info.plist for dev build
plutil -replace CFBundleIdentifier -string "com.danneu.danterm-dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIconName -string "AppIcon-dev" "$APP_PATH/Contents/Info.plist"
plutil -replace DanTermRecordsFlightTape -bool true "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign "Apple Development" --entitlements "$SCRIPT_DIR/dev-entitlements.plist" "$APP_PATH"

# Quit a running instance at the last possible moment -- after the compile, just
# before the install replaces the bundle out from under it. Waiting for the
# process to actually exit is the point: `killall` only sends SIGTERM, and a
# caller that runs `open` against a half-dead instance gets LaunchServices error
# -600 (procNotFound) because `open` reuses the still-registered bundle id.
if [ -n "$KILL_RUNNING" ]; then
    killall "DanTerm Dev" 2>/dev/null || true
    for _ in $(seq 1 50); do
        killall -0 "DanTerm Dev" 2>/dev/null || break
        sleep 0.1
    done
fi

echo "Built: $APP_PATH"
if [ -n "$INSTALL" ]; then
    # Install the freshly built app so launchers using ~/Applications are in sync.
    mkdir -p "$HOME/Applications"
    rm -rf "$INSTALL_APP"
    cp -R "$APP_PATH" "$INSTALL_APP"

    # Force macOS to rescan the app bundle so icon changes take effect immediately.
    "$LSREGISTER" -f "$INSTALL_APP"
    echo "Installed: $INSTALL_APP"
fi
