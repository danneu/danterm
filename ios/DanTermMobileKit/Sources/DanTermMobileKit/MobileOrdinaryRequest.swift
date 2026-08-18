// The only requests the phone may send outside its claim gesture.
//
// It exists so the compiler carries the claim-gesture contract. The session model's
// ordinary effects carry this type rather than a bare `IpcRequest`, and this type can
// only be built from the two forms that are not a resize -- so an ordinary branch cannot
// send a resize whatever it constructs. The claim and release gesture reaches a separate
// entry point whose effect type carries the resize instead.
import DanTermProtocol

/// Wraps one request the phone sends on a serving stream, restricted by construction to
/// the forms that are not a pane resize.
///
/// The initializer is private and the file holds nothing else, so the two factories below
/// are the complete list of requests an ordinary session branch can produce.
public struct MobileOrdinaryRequest: Equatable, Sendable {
    /// The wire request to send. Read by the interpreter, which adds only the JSON-RPC id.
    public let request: IpcRequest

    private init(_ request: IpcRequest) {
        self.request = request
    }

    /// Input for the pane the phone is showing.
    public static func paneInput(pane: PaneId, input: IpcPaneInput) -> MobileOrdinaryRequest {
        MobileOrdinaryRequest(.paneInput(pane: pane, input: input))
    }

    /// The tape subscription the phone reads a pane through. The phone joins over a remote
    /// link, so it takes the server's bounded default history rather than paying for a
    /// pane's whole retained scrollback on every join.
    public static func paneTape(
        pane: PaneId,
        start: PaneTapeStartPosition
    ) -> MobileOrdinaryRequest {
        MobileOrdinaryRequest(.paneTape(
            pane: pane,
            follow: true,
            start: start,
            policy: .reconstructible(
                historyBudgetBytes: PaneTapeSyncPolicy.defaultHistoryBudgetBytes
            )
        ))
    }
}
