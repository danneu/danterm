#!/usr/bin/env bash
#
# The AppKit UI suite. This is a raw `swiftc` build, not a SwiftPM test target,
# and the reason is substitution, not GhosttyKit (the original rationale, now
# obsolete) and not the WindowServer requirement.
#
# The one thing this build does that a test target cannot: it compiles the
# production view files into the SAME module as `tests-ui/*TestShim.swift`, so
# the fake `AppRuntime` and the fake `TerminalPaneSessionController` REPLACE the
# real ones -- no dependency injection in production code required. In a test
# target the views are already compiled against `DanTerm.AppRuntime` and
# `TerminalPaneSession.TerminalPaneSessionController`, and the real ones cannot
# be built in a test (`AppRuntime.init` binds the live IPC socket; the
# controller forks a PTY child). That is what `-D DANTERM_UI_TEST` is for in
# `SwiftTerminalSessionView.swift` and `ThemeRenderBridge.swift`: it suppresses
# the real engine imports so the fakes win. Adding a view here ("promotion")
# is the price of that seam.
#
# Full finding, including what was measured and the way out:
# docs/design/2026-08-06-ui-harness-whole-module-substitution.md
#
# Kept out of `just test` separately, because it needs a WindowServer connection.
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

# The chip artwork and its renderer live in their own package now, and the AppKit
# chip files import it. Built here the same way DanTermProtocol is, against that
# module, so the harness draws through the shipped renderer rather than a copy.
echo "Compiling ChipArtwork..."
xcrun swiftc \
    -emit-module -emit-library -static \
    -module-name ChipArtwork \
    -I "$PROTO_BUILD" \
    -emit-module-path "$PROTO_BUILD/ChipArtwork.swiftmodule" \
    -o "$PROTO_BUILD/libChipArtwork.a" \
    "$SCRIPT_DIR"/lib/ChipArtwork/Sources/ChipArtwork/*.swift

# A leaf target with no imports and no dependencies, built as a module so the harness
# compiles the real lifecycle and geometry vocabulary instead of re-declaring it.
echo "Compiling PaneProcessLifecycle..."
xcrun swiftc \
    -emit-module -emit-library -static \
    -module-name PaneProcessLifecycle \
    -emit-module-path "$PROTO_BUILD/PaneProcessLifecycle.swiftmodule" \
    -o "$PROTO_BUILD/libPaneProcessLifecycle.a" \
    "$SCRIPT_DIR/lib/TerminalPTY/Sources/PaneProcessLifecycle/LaunchPolicy.swift" \
    "$SCRIPT_DIR/lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift"

echo "Compiling UI tests..."
(
    cd "$PROTO_BUILD"
    xcrun swiftc -D DANTERM_UI_TEST -o "$UI_TEST_BINARY" \
        -parse-as-library \
        -I "$PROTO_BUILD" \
        -L "$PROTO_BUILD" \
        -lDanTermProtocol \
        -lChipArtwork \
        -lPaneProcessLifecycle \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/AgentSession.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Model.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Projections.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TabTodo.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoPopoverState.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TodoShortcutCatalog.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ScrollbarMath.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Persistence.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Msg.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ReconcileFollowUps.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/Command.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/PaneLifecycleReducer.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/PaneLifecycleConsumers.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/PaneLifecycleIpcAdapter.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/TerminalMetadataBounds.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ThemeCatalogDocument.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/DragDropInput.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalCore/ActivatableWebURI.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalCore/TerminalSemanticEvent.swift" \
        "$SCRIPT_DIR/lib/TerminalPTY/Sources/TerminalPTYHost/PaneSemanticEvent.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalCore/TerminalSearchStatus.swift" \
        "$SCRIPT_DIR/app/PaneInputOrigin.swift" \
        "$SCRIPT_DIR/app/TerminalLinkURL.swift" \
        "$SCRIPT_DIR/app/DragDropPasteboard.swift" \
        "$SCRIPT_DIR/app/TextPasteboard.swift" \
        "$SCRIPT_DIR/app/SingleLineLabel.swift" \
        "$SCRIPT_DIR/app/BadgeLabel.swift" \
        "$SCRIPT_DIR/app/ChipView.swift" \
        "$SCRIPT_DIR/app/MenuCommandPolicy.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/PaneGridOverride.swift" \
        "$SCRIPT_DIR/app/TerminalSession.swift" \
        "$SCRIPT_DIR/app/AppRuntimeSchedulingLifecycle.swift" \
        "$SCRIPT_DIR/app/AppPresentationLifecycle.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/Debouncer.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/FontAvailability.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/PaneTapeFollow.swift" \
        "$SCRIPT_DIR/lib/DanTermSupport/Sources/DanTermSupport/PaneTapeStreamState.swift" \
        "$SCRIPT_DIR/app/DanTermConfigStore.swift" \
        "$SCRIPT_DIR/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalWheelNormalizer.swift" \
        "$SCRIPT_DIR/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalGridSizing.swift" \
        "$SCRIPT_DIR/lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderFit.swift" \
        "$SCRIPT_DIR/tests-ui/SwiftTerminalSessionViewTestShim.swift" \
        "$SCRIPT_DIR/app/SwiftTerminalSessionView.swift" \
        "$SCRIPT_DIR/app/TerminalFrameRateSampler.swift" \
        "$SCRIPT_DIR/app/TerminalDeliveryShapeSampler.swift" \
        "$SCRIPT_DIR/app/PaneLayoutRectBridge.swift" \
        "$SCRIPT_DIR/app/PaneDividerView.swift" \
        "$SCRIPT_DIR/app/TodoInputView.swift" \
        "$SCRIPT_DIR/app/TodoRowView.swift" \
        "$SCRIPT_DIR/app/TodoShortcutHelpView.swift" \
        "$SCRIPT_DIR/app/TodoPopoverScope.swift" \
        "$SCRIPT_DIR/app/TodoPopoverController.swift" \
        "$SCRIPT_DIR/app/TabTodoPopoverScope.swift" \
        "$SCRIPT_DIR/app/PaneTodoPopoverScope.swift" \
        "$SCRIPT_DIR/app/AlertsPopoverView.swift" \
        "$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift" \
        "$SCRIPT_DIR/tests-ui/TypedIdTestInit.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarViewTestShim.swift" \
        "$SCRIPT_DIR/app/TodoToolbarButton.swift" \
        "$SCRIPT_DIR/app/SearchOverlayView.swift" \
        "$SCRIPT_DIR/app/LinkPreviewView.swift" \
        "$SCRIPT_DIR/app/ObserveOnMain.swift" \
        "$SCRIPT_DIR/app/ScrollableTerminalView.swift" \
        "$SCRIPT_DIR/app/PaneWrapperView.swift" \
        "$SCRIPT_DIR/app/PaneHost.swift" \
        "$SCRIPT_DIR/app/SplitContainerView.swift" \
        "$SCRIPT_DIR/app/PaneFocusReconciliation.swift" \
        "$SCRIPT_DIR/app/TableContextMenuHighlight.swift" \
        "$SCRIPT_DIR/app/SidebarCellViews.swift" \
        "$SCRIPT_DIR/app/SidebarView.swift" \
        "$SCRIPT_DIR/app/SidebarReconcileDriver.swift" \
        "$SCRIPT_DIR/app/ReconcileOutbox.swift" \
        "$SCRIPT_DIR/app/SwitcherPanel.swift" \
        "$SCRIPT_DIR/app/BellToolbarButton.swift" \
        "$SCRIPT_DIR/app/TitlebarDragView.swift" \
        "$SCRIPT_DIR/app/WindowChromeView.swift" \
        "$SCRIPT_DIR/app/PaneStripView.swift" \
        "$SCRIPT_DIR/app/ThemeCatalog.swift" \
        "$SCRIPT_DIR/app/ThemeRenderBridge.swift" \
        "$SCRIPT_DIR/app/ThemeSwatchViews.swift" \
        "$SCRIPT_DIR/app/ThemeBrowserView.swift" \
        "$SCRIPT_DIR/app/RemoteThemePickerSheet.swift" \
        "$SCRIPT_DIR/app/PreferencesPanel.swift" \
        "$SCRIPT_DIR/app/DialogActionRow.swift" \
        "$SCRIPT_DIR/app/ConfirmationCommandItemView.swift" \
        "$SCRIPT_DIR/app/ConfirmationPanel.swift" \
        "$SCRIPT_DIR/tests-ui/ChipViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/PaneStripViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/MenuCommandPolicyTests.swift" \
        "$SCRIPT_DIR/tests-ui/TodoInputViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarTestSupport.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarSelectionCacheTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarRenameRecycleTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarContextMenuTests.swift" \
        "$SCRIPT_DIR/tests-ui/SidebarProjectionRowTests.swift" \
        "$SCRIPT_DIR/tests-ui/SplitContainerViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/LinkPreviewViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/PaneWrapperViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/ObserveOnMainTests.swift" \
        "$SCRIPT_DIR/tests-ui/ScrollableTerminalViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/TodoPopoverDragTestSupport.swift" \
        "$SCRIPT_DIR/tests-ui/TabTodoPopoverViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/TodoPopoverViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/ThemeBrowserViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/RemoteThemePickerSheetTests.swift" \
        "$SCRIPT_DIR/tests-ui/PaneSplitViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/TerminalBackendBoundaryTests.swift" \
        "$SCRIPT_DIR/tests-ui/AppPresentationLifecycleTests.swift" \
        "$SCRIPT_DIR/tests-ui/DanTermConfigStoreTests.swift" \
        "$SCRIPT_DIR/tests-ui/SwiftTerminalSessionViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/IOSurfaceLayerContentsTests.swift" \
        "$SCRIPT_DIR/tests-ui/AlertsPopoverViewTests.swift" \
        "$SCRIPT_DIR/tests-ui/PreferencesPanelTests.swift" \
        "$SCRIPT_DIR/tests-ui/ConfirmationPanelTests.swift" \
        "$SCRIPT_DIR/tests-ui/DialogActionRowTests.swift" \
        "$SCRIPT_DIR/tests-ui/SingleLineLabelTests.swift" \
        -framework Cocoa
)
echo "Running UI tests..."
"$UI_TEST_BINARY"
