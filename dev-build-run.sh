#!/usr/bin/env bash
#
# Build DanTerm Dev (which installs to ~/Applications) and run it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_APP="$HOME/Applications/DanTerm Dev.app"

# Build
"$SCRIPT_DIR/dev-build.sh"

# Kill previous instance
killall "DanTerm Dev" 2>/dev/null || true

# Run installed app
"$INSTALL_APP/Contents/MacOS/DanTerm Dev"
