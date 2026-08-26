// The one declaration of "what terminal am I?": the name and version an embedder
// gives the engine to report. Nothing that decides *how* an identity reaches a
// child process or a query reply belongs here -- that is launch assembly's and
// the query handler's business.

/// Names the product an embedder ships, so the engine never has to.
///
/// One value feeds both channels that answer the question -- the advertised
/// `TERM_PROGRAM` / `TERM_PROGRAM_VERSION` pair and the XTVERSION reply -- so the
/// two cannot disagree. There is deliberately no default: an identity the engine
/// invented would be a product name the engine owns.
public struct TerminalProductIdentity: Equatable, Sendable {
    /// Product name, reported verbatim.
    public let name: String
    /// Product version, reported verbatim.
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
