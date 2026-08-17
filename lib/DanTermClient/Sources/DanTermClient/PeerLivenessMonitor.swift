// The client half of the peer-liveness contract: one watchdog per session that pays the
// ping obligation and bounds the client's own wait for a byte.
//
// It sits beside the conversation rather than inside it because the two jobs are
// different: the session frames and correlates, this one only keeps time. What does not
// belong here is the number itself -- the server states the bound and the session hands
// it over -- and what a dead peer means to a user, which is the shell's to word.
import Foundation
import DanTermProtocol

/// Receives the monitor's two effects. It exists so the monitor holds its session weakly:
/// the watchdog thread outlives nothing, and a session dropped without a close must not
/// be kept alive by the thread that watches it.
protocol PeerLivenessMonitorDelegate: AnyObject {
    /// Writes one heartbeat. Returning false means the write failed, which ends the
    /// connection now rather than leaving a silently non-pinging stream behind.
    func sendLivenessPing(_ request: JsonRpcRequest) -> Bool

    /// Reports that no byte arrived within the bound, so the peer is gone.
    func peerDeclaredSilent()
}

/// Watches one session's stream for peer silence and sends its unconditional heartbeat.
///
/// Both jobs live on one schedule on purpose. The cadence is half the bound and depends on
/// nothing else the session sends or receives, so each ping feeds the server's deadline and
/// each pong feeds this one, whether the connection is idle, talking, or draining a flood.
///
/// Silence is what a waiting reader observes: the monitor measures how long the session's
/// current `receive` has been waiting for its first byte, so a large record trickling in
/// pieces keeps feeding the deadline while a stream with nothing at all on it runs out. A
/// session that is not reading is not waiting, and is never declared dead on its own quiet.
final class PeerLivenessMonitor: @unchecked Sendable {
    /// Marks a request as this client's own heartbeat so its reply can be absorbed before
    /// any consumer sees it. A recognizable prefix rather than a set of outstanding ids:
    /// nothing has to be remembered, so nothing can grow.
    static let pingIdPrefix = "danterm-liveness-"

    /// True for a reply this client sent only to keep the connection fed.
    static func isPingReply(id: JSONValue?) -> Bool {
        guard case .string(let text) = id else { return false }
        return text.hasPrefix(pingIdPrefix)
    }

    private weak var delegate: PeerLivenessMonitorDelegate?
    private let condition = NSCondition()
    private var bound: IpcLivenessBound
    /// False until the handshake succeeds. Before then this client has sent nothing and
    /// agreed nothing, so the only thing to watch is whether the hello arrives at all.
    private var pingsStarted = false
    private var readWaitingSince: TimeInterval?
    private var lastPingAt = TimeInterval(0)
    private var stopped = false
    private var pingCount = 0

    /// Starts watching immediately, under the client's own establishment bound, because
    /// the wait for the server's opening hello has to be bounded before the server has
    /// stated the number that bounds everything after it.
    init(establishmentBound: IpcLivenessBound, delegate: PeerLivenessMonitorDelegate) {
        self.bound = establishmentBound
        self.delegate = delegate
        let thread = Thread { [self] in run() }
        thread.name = "danterm-client-liveness"
        thread.start()
    }

    /// Adopts the bound the server advertised and begins the heartbeat. From here the
    /// advertised number governs the whole stream, the first reply included.
    func adoptAdvertisedBound(_ advertised: IpcLivenessBound) {
        condition.lock()
        bound = advertised
        pingsStarted = true
        lastPingAt = Self.now
        condition.broadcast()
        condition.unlock()
    }

    /// Marks the session as waiting for its next byte, which is what silence is measured
    /// against. Every returned chunk ends one wait and begins the next, so the measure
    /// stays byte-level rather than frame-level.
    func readWaitBegan() {
        condition.lock()
        readWaitingSince = Self.now
        condition.broadcast()
        condition.unlock()
    }

    func readWaitEnded() {
        condition.lock()
        readWaitingSince = nil
        condition.unlock()
    }

    /// Signals the watchdog to finish. It deliberately does not wait for the thread: the
    /// monitor calls into the session, and the session calls this, so joining here would
    /// let a dead peer deadlock the very teardown that reclaims its resources.
    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    /// How many heartbeats this monitor has written, for tests that assert the cadence.
    var observedPingCount: Int {
        condition.withLock { pingCount }
    }

    private func run() {
        while true {
            condition.lock()
            while stopped == false {
                let now = Self.now
                if let readWaitingSince, now - readWaitingSince >= bound.seconds { break }
                if pingsStarted, now >= lastPingAt + bound.pingInterval { break }
                var wake = pingsStarted ? lastPingAt + bound.pingInterval : now + bound.seconds
                if let readWaitingSince { wake = min(wake, readWaitingSince + bound.seconds) }
                condition.wait(until: Date(timeIntervalSinceNow: max(wake - now, 0.001)))
            }
            if stopped {
                condition.unlock()
                return
            }
            let now = Self.now
            let silent = readWaitingSince.map { now - $0 >= bound.seconds } ?? false
            var pingId: JSONValue?
            if silent == false, pingsStarted, now >= lastPingAt + bound.pingInterval {
                lastPingAt = now
                pingCount += 1
                pingId = .string("\(Self.pingIdPrefix)\(pingCount)")
            }
            condition.unlock()

            guard let delegate else { return }
            if silent {
                delegate.peerDeclaredSilent()
                return
            }
            if let pingId {
                let request = JsonRpcRequest(id: pingId, method: IpcRequestMethod.ping.rawValue)
                guard delegate.sendLivenessPing(request) else {
                    // A heartbeat this client cannot write means the stream is already
                    // gone. Reporting it now beats leaving a non-pinging connection for
                    // the server to reclaim a whole bound later.
                    delegate.peerDeclaredSilent()
                    return
                }
            }
        }
    }

    /// A monotonic clock, so a wall-clock correction cannot make a healthy peer look dead.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
