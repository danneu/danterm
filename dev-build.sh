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
LIB_DIR="$SCRIPT_DIR/lib"
BUILD_CONFIGURATION="${SWIFT_CONFIGURATION:-debug}"

# Build with SwiftPM (incremental — only recompiles changed files).
echo "Compiling..."
swift_build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build"
BIN_PATH="$SCRIPT_DIR/.spm-build/$BUILD_CONFIGURATION"
if [[ ! -d "$BIN_PATH" ]]; then
    echo "Error: SwiftPM did not create the $BUILD_CONFIGURATION app product directory: $BIN_PATH" >&2
    exit 1
fi
swift_build \
    --package-path "$LIB_DIR/TerminalPTY" \
    --build-path "$SCRIPT_DIR/.spm-build/TerminalPTY" \
    --product PTYSessionBootstrap
BOOTSTRAP_BIN_PATH="$SCRIPT_DIR/.spm-build/TerminalPTY/$BUILD_CONFIGURATION"
if [[ ! -d "$BOOTSTRAP_BIN_PATH" ]]; then
    echo "Error: SwiftPM did not create the $BUILD_CONFIGURATION bootstrap product directory: $BOOTSTRAP_BIN_PATH" >&2
    exit 1
fi

LAYOUT_PLAN="$BUILD_DIR/bundle-layout-development.json"
mkdir -p "$(dirname "$LAYOUT_PLAN")"
"$BIN_PATH/DanTermBundleLayoutTool" development > "$LAYOUT_PLAN"
PATH="$PATH:$SCRIPT_DIR/scripts" assemble-app-bundle.sh \
    "$APP_PATH" "$LAYOUT_PLAN" "$SCRIPT_DIR" \
    --product "DanTerm=$BIN_PATH/DanTerm" \
    --product "DanTermCLI=$BIN_PATH/DanTermCLI" \
    --product "DanTermInstanceIdentityTool=$BIN_PATH/DanTermInstanceIdentityTool" \
    --product "PTYSessionBootstrap=$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap"

PATH="$PATH:$SCRIPT_DIR/scripts" sign-app-bundle.sh \
    "$APP_PATH" "$LAYOUT_PLAN" "$SCRIPT_DIR" "Apple Development" \
    --entitlements "$SCRIPT_DIR/dev-entitlements.plist"

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
