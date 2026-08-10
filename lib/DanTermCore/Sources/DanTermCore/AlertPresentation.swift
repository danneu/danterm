// Resolves an incoming alert into the slots a macOS notification actually has.
// This is derived presentation, not stored state, so it lives apart from
// Model.swift -- nothing here belongs to AppModel.
//
// The sender's body is never rewritten. Provenance goes in the title slot and
// pane location in the subtitle slot, because a body prefixed with "claude: "
// would leave the stored alert disagreeing with what the sender wrote and would
// double up the moment a sender supplies its own title.
import Foundation

/// The notification slots that are derived rather than sent: who the alert came
/// from and where that pane lives. Built once per alert and used for both the
/// stored `AlertModel` and the `.sendNotification` command, so the alerts
/// popover and the macOS banner can't drift apart.
struct AlertPresentation: Equatable {
    let title: String
    let subtitle: String?
}

/// Resolve the title and subtitle for an alert raised by `paneId`.
///
/// The title answers "who": the sender's own title when it supplies one (OSC 777
/// does, OSC 9 does not), otherwise the pane title. An attached agent session
/// and the running command report are earlier tiers in that order.
///
/// The subtitle answers "where", and is dropped when it would only restate the
/// title: an unnamed single-pane tab derives its own title from that same pane.
func alertPresentation(
    senderTitle: String,
    paneId: PaneId,
    livePaneState: LivePaneStateView,
    in model: AppModel
) -> AlertPresentation {
    let semantics = livePaneState.semantics(for: paneId)
    let paneTitle = model.pane(paneId)?.title ?? "Terminal"
    let title: String
    switch semantics.agent {
    case .attached(let session, _):
        title = "\(AgentCatalog.displayName(for: session.kind)) \(session.sessionId)"
    case .none:
        if case .running(let command) = semantics.command {
            title = command
        } else {
            title = senderTitle.isEmpty ? paneTitle : senderTitle
        }
    }

    guard let tab = tabForPane(paneId, in: model) else {
        return AlertPresentation(title: title, subtitle: nil)
    }

    var location = tab.displayTitle
    let paneIds = allPaneIds(tab.rootNode)
    if paneIds.count > 1, let index = paneIds.firstIndex(of: paneId) {
        location += " - pane \(index + 1)"
    }

    return AlertPresentation(title: title, subtitle: location == title ? nil : location)
}
