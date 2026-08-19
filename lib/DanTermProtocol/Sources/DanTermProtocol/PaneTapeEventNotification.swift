// The envelope a `pane.tape.event` notification carries: the subscription it belongs to and
// the record it delivers. It sits beside the record shape at the protocol boundary for the
// same reason that shape does -- the producer and every reader must agree on both keys, and a
// spelling declared on one side alone compiles clean everywhere and stops a stream mid-flight.
//
// The record's own keys are in PaneTapeRecord.swift, and the method name in Methods.swift.
// Assembling a multi-part transfer out of the records this envelope delivers is a reader's
// job and does not belong here.

/// The params object of a `pane.tape.event` notification, generic over the record it carries.
///
/// The keys come from these two property declarations, so a second spelling of them cannot
/// exist: the producer instantiates this with its own typed record and encodes, and a reader
/// instantiates it with `JSONValue` and decodes. The record stays a type parameter rather than
/// the typed record family because a reader must forward a record kind this build does not
/// know, and because the producer's whole line -- envelope, record, and the recorded event
/// inside it -- is then written in one JSON pass.
public struct PaneTapeEventNotification<Record> {
    /// Names the stream this record belongs to, so a client following several panes on one
    /// socket can route it.
    public let subscription: String
    /// The one record this notification delivers, in whatever form its end of the wire holds:
    /// the producer's typed record going out, and the parsed tree coming back in.
    public let record: Record

    /// Creates one notification's params from the two facts it states.
    public init(subscription: String, record: Record) {
        self.subscription = subscription
        self.record = record
    }
}

extension PaneTapeEventNotification: Equatable where Record: Equatable {}
extension PaneTapeEventNotification: Sendable where Record: Sendable {}
extension PaneTapeEventNotification: Encodable where Record: Encodable {}
extension PaneTapeEventNotification: Decodable where Record: Decodable {}

extension PaneTapeEventNotification where Record: Decodable {
    /// Recognises one notification off the wire, returning nil when it is not a pane-tape
    /// event or when its params are not this shape.
    ///
    /// Recognition lives with the shape so no module outside this one spells any part of the
    /// envelope. There is no partial value: a client holding one would route a record to no
    /// subscription, or forward a record that was never there.
    public init?(method: String, params: JSONValue?) {
        guard method == Methods.paneTapeEvent,
              let params,
              let decoded = try? JSONValueDecoder().decode(Self.self, from: params)
        else { return nil }
        self = decoded
    }
}
