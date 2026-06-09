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

echo "Compiling UI tests..."
(
    cd "$PROTO_BUILD"
    xcrun swiftc -o /tmp/danterm-ui-tests \
        -parse-as-library \
        -I "$PROTO_BUILD" \
        -L "$PROTO_BUILD" \
        -lDanTermProtocol \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/AgentSession.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Model.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Projections.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TabTodo.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Persistence.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Msg.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Command.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DanTermConfig.swift" \
        "$SCRIPT_DIR/app/BadgeLabel.swift" \
        "$SCRIPT_DIR/app/MenuCommandPolicy.swift" \
        "$SCRIPT_DIR/app/PaneSplitView.swift" \
        "$SCRIPT_DIR/app/TodoInputView.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift" \
        "$SCRIPT_DIR/tests-ui/TypedIdTestInit.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarViewTestShim.swift" \
        "$SCRIPT_DIR/app/SplitContainerView.swift" \
        "$SCRIPT_DIR/app/SidebarView.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarBadgeTests.swift" \
        "$SCRIPT_DIR/tests-ui/MenuCommandPolicyTests.swift" \
        "$SCRIPT_DIR/tests-ui/TodoInputViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarSelectionCacheTests.swift" \
        "$SCRIPT_DIR/tests-ui/SplitContainerViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/PaneSplitViewTests.swift" \
        -framework Cocoa
)
echo "Running UI tests..."
/tmp/danterm-ui-tests
