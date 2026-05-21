#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_BUILD="$(mktemp -d)"
trap 'rm -rf "$PROTO_BUILD"' EXIT

echo "Compiling DanTermProtocol..."
xcrun swiftc \
    -emit-module -emit-library -static \
    -module-name DanTermProtocol \
    -emit-module-path "$PROTO_BUILD/DanTermProtocol.swiftmodule" \
    -o "$PROTO_BUILD/libDanTermProtocol.a" \
    "$SCRIPT_DIR"/lib/DanTermProtocol/Sources/DanTermProtocol/*.swift

echo "Compiling tests..."
(
    cd "$PROTO_BUILD"
    xcrun swiftc -o /tmp/danterm-tests \
        -parse-as-library \
        -I "$PROTO_BUILD" \
        -L "$PROTO_BUILD" \
        -lDanTermProtocol \
        "$SCRIPT_DIR/app/Model.swift" \
        "$SCRIPT_DIR/app/ModelOperations.swift" \
        "$SCRIPT_DIR/app/Msg.swift" \
        "$SCRIPT_DIR/app/Effect.swift" \
        "$SCRIPT_DIR/app/TerminalLaunchEnvironment.swift" \
        "$SCRIPT_DIR/app/Update.swift" \
        "$SCRIPT_DIR/app/IpcConnection.swift" \
        "$SCRIPT_DIR/app/CLIPathInstaller.swift" \
        "$SCRIPT_DIR/app/DragDropInput.swift" \
        "$SCRIPT_DIR/app/DropZone.swift" \
        "$SCRIPT_DIR/app/ScrollbarMath.swift" \
        "$SCRIPT_DIR/app/ThemeColorParser.swift" \
        "$SCRIPT_DIR/app/DanTermConfig.swift" \
        "$SCRIPT_DIR/app/TodoPopoverState.swift" \
        "$SCRIPT_DIR/app/TodoInputCommand.swift" \
        "$SCRIPT_DIR/app/TodoShortcutCatalog.swift" \
        "$SCRIPT_DIR"/tests/*.swift
)
echo "Running tests..."
/tmp/danterm-tests
