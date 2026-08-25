// The text the phone renders outside the grid, with its presentation already stated.
//
// A terminal-authored string reaches a UIKit label only through `MobileDisplayText`, whose
// single constructor decides text-versus-emoji by the same pinned table the grid fallback
// uses. The Mac's roster projection has already done the text hygiene (controls, bidi
// overrides, whitespace); this file holds the other half, which must live on the phone
// because the table is `TerminalCore`'s and the pure core may not name it.
//
// What does not belong here: any layout or font choice, and the roster's identity facts,
// which `MobilePaneRow` carries beside the prepared text.
import DanTermProtocol
import TerminalCore

/// A string prepared for a phone label. Constructing one is the only way to get a title
/// in front of UIKit, so an unprepared string cannot reach a label by any route.
public struct MobileDisplayText: Equatable, Sendable {
    public let text: String

    /// States the presentation Unicode defines for each single-scalar grapheme cluster
    /// that is a default-text variation base, and leaves every other cluster as it came.
    ///
    /// Segmentation is the host's own: the label lays the string out by those rules, and
    /// there is no terminal cell here to disagree with.
    public init(preparing raw: String) {
        var prepared = ""
        prepared.reserveCapacity(raw.utf8.count)
        for cluster in raw {
            prepared.append(cluster)
            if let selector = terminalPresentationSelectorToAppend(for: cluster.unicodeScalars) {
                prepared.unicodeScalars.append(selector)
            }
        }
        text = prepared
    }
}

/// One roster pane as the shell may show it: identity and chip straight from the roster,
/// every title as prepared display text.
public struct MobilePaneRow: Equatable, Sendable {
    public let paneId: PaneId
    public let groupName: MobileDisplayText
    public let tabTitle: MobileDisplayText
    public let paneTitle: MobileDisplayText
    public let chip: ChipKind

    init(_ item: PaneRosterItem) {
        paneId = item.paneId
        groupName = MobileDisplayText(preparing: item.groupName)
        tabTitle = MobileDisplayText(preparing: item.tabTitle)
        paneTitle = MobileDisplayText(preparing: item.paneTitle)
        chip = item.chip
    }
}
