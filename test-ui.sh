#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_BUILD="$(mktemp -d)"
UI_TEST_BINARY="$PROTO_BUILD/danterm-ui-tests"
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
    xcrun swiftc -D DANTERM_UI_TEST -o "$UI_TEST_BINARY" \
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
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoPopoverState.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoShortcutCatalog.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Persistence.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Msg.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Command.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TerminalMetadataBounds.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DanTermConfig.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DanTermConfigDocument.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ThemeCatalogDocument.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DragDropInput.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalDamageSpans.swift" \
        "$SCRIPT_DIR/app/DragDropPasteboard.swift" \
        "$SCRIPT_DIR/app/BadgeLabel.swift" \
        "$SCRIPT_DIR/app/MenuCommandPolicy.swift" \
        "$SCRIPT_DIR/app/TerminalBackend.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/FontAvailability.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/PaneTapeFollow.swift" \
        "$SCRIPT_DIR/app/DanTermConfigStore.swift" \
        "$SCRIPT_DIR/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalWheelNormalizer.swift" \
        "$SCRIPT_DIR/tests-ui/SwiftTerminalSessionViewTestShim.swift" \
        "$SCRIPT_DIR/app/SwiftTerminalSessionView.swift" \
        "$SCRIPT_DIR/app/PaneSplitView.swift" \
        "$SCRIPT_DIR/app/TodoInputView.swift" \
        "$SCRIPT_DIR/app/TodoRowView.swift" \
        "$SCRIPT_DIR/app/TodoShortcutHelpView.swift" \
        "$SCRIPT_DIR/app/TodoPopoverControllerBase.swift" \
        "$SCRIPT_DIR/app/TabTodoPopoverView.swift" \
        "$SCRIPT_DIR/app/TodoPopoverView.swift" \
        "$SCRIPT_DIR/app/AlertsPopoverView.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift" \
        "$SCRIPT_DIR/tests-ui/TypedIdTestInit.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarViewTestShim.swift" \
        "$SCRIPT_DIR/app/TodoToolbarButton.swift" \
        "$SCRIPT_DIR/app/SearchOverlayView.swift" \
        "$SCRIPT_DIR/app/LinkPreviewView.swift" \
        "$SCRIPT_DIR/app/PaneWrapperView.swift" \
        "$SCRIPT_DIR/app/SplitContainerView.swift" \
        "$SCRIPT_DIR/app/SidebarView.swift" \
        "$SCRIPT_DIR/app/ThemeCatalog.swift" \
        "$SCRIPT_DIR/app/ThemeRenderBridge.swift" \
        "$SCRIPT_DIR/app/ThemeSwatchViews.swift" \
        "$SCRIPT_DIR/app/ThemeBrowserView.swift" \
        "$SCRIPT_DIR/app/RemoteThemePickerSheet.swift" \
        "$SCRIPT_DIR/app/PreferencesPanel.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarBadgeTests.swift" \
        "$SCRIPT_DIR/tests-ui/MenuCommandPolicyTests.swift" \
        "$SCRIPT_DIR/tests-ui/TodoInputViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarSelectionCacheTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarRenameRecycleTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarContextMenuTests.swift" \
        "$SCRIPT_DIR/tests-ui/SplitContainerViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/LinkPreviewViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/PaneWrapperViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/TabTodoPopoverViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/TodoPopoverViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/ThemeBrowserViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/RemoteThemePickerSheetTests.swift" \
        "$SCRIPT_DIR/tests-ui/PaneSplitViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/TerminalBackendBoundaryTests.swift" \
        "$SCRIPT_DIR/tests-ui/DanTermConfigStoreTests.swift" \
        "$SCRIPT_DIR/tests-ui/SwiftTerminalSessionViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/AlertsPopoverViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/PreferencesPanelTests.swift" \
        -framework Cocoa
)
echo "Running UI tests..."
"$UI_TEST_BINARY"
