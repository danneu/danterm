// Runtime-owned lifetime root for one terminal session and its persistent pane chrome.
import Cocoa

/// Keeps a terminal session and its wrapper alive together across container tree edits.
@MainActor
final class PaneHost {
    let session: any TerminalSession
    let wrapper: PaneWrapperView

    init(paneId: PaneId, session: any TerminalSession, runtime: AppRuntime) {
        self.session = session
        self.wrapper = PaneWrapperView(
            paneId: paneId,
            terminalView: session,
            isZoomed: false,
            hasSplits: false,
            runtime: runtime
        )
    }
}
