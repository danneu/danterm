#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Compiling UI tests..."
xcrun swiftc -o /tmp/danterm-ui-tests \
    -parse-as-library \
    "$SCRIPT_DIR/app/Model.swift" \
    "$SCRIPT_DIR/app/ModelOperations.swift" \
    "$SCRIPT_DIR/app/Msg.swift" \
    "$SCRIPT_DIR/app/Effect.swift" \
    "$SCRIPT_DIR/app/PaneSplitView.swift" \
    "$SCRIPT_DIR/tests-ui/PaneSplitViewTests.swift" \
    -framework Cocoa
echo "Running UI tests..."
/tmp/danterm-ui-tests
