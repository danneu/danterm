#!/usr/bin/env bash
#
# Build DanTerm Dev (which installs to ~/Applications) and run it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_APP="$HOME/Applications/DanTerm Dev.app"

# Build. --kill-running quits a running instance inside the build script, after
# the compile but immediately before it replaces the installed bundle, so the old
# app stays usable for the whole compile and is fully gone before `open` below.
"$SCRIPT_DIR/dev-build.sh" "$@" --kill-running

# Run installed app via LaunchServices: gives Dock launch feedback, lets the
# WindowServer activate the window normally, and returns the shell prompt
# immediately instead of blocking on the app for its whole lifetime.
open "$INSTALL_APP"
