#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Compiling tests..."
xcrun swiftc -o /tmp/danterm-tests \
    -parse-as-library \
    "$SCRIPT_DIR/app/Model.swift" \
    "$SCRIPT_DIR/app/ModelOperations.swift" \
    "$SCRIPT_DIR/app/Msg.swift" \
    "$SCRIPT_DIR/app/Effect.swift" \
    "$SCRIPT_DIR/app/Update.swift" \
    "$SCRIPT_DIR/app/DragDropInput.swift" \
    "$SCRIPT_DIR/app/DropZone.swift" \
    "$SCRIPT_DIR/app/ScrollbarMath.swift" \
    "$SCRIPT_DIR/app/ThemeColorParser.swift" \
    "$SCRIPT_DIR/app/DanTermConfig.swift" \
    "$SCRIPT_DIR"/tests/*.swift
echo "Running tests..."
/tmp/danterm-tests
