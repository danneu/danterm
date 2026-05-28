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
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Model.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Projections.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TabTodo.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Persistence.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Msg.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Command.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TerminalLaunchEnvironment.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Update.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/IpcConnection.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/CLIPathInstaller.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DragDropInput.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DropZone.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ScrollbarMath.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TickCoalescer.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Debouncer.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/SurfaceGeometry.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ThemeColorParser.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DanTermConfig.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoPopoverState.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoShortcutCatalog.swift" \
        "$SCRIPT_DIR"/tests/*.swift
)
echo "Running tests..."
/tmp/danterm-tests
