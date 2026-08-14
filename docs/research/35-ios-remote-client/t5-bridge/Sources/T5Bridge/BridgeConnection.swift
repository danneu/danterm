// One bridged conversation: a phone's TCP connection on one side, a fresh
// DanTerm control-socket connection on the other.
//
// THE BOUND THIS FILE OWNS. The research ledger states that the bridge is the
// only place an unbounded per-subscriber buffer can exist at all -- the app side
// keeps a cursor and two booleans per subscription and stores no events, and the
// ring is the flight recorder. So the invariant to carry across the network is
// that the bridge buffers at most one in-flight batch per subscriber, and this
// is the file where that bound lives.
//
// It is enforced structurally rather than asserted: the bridge owns no queue at
// all. Each direction reads at most one buffer, writes every byte of it before
// reading again, and so holds `readBufferBytes` and nothing more. When the phone
// is slower than the pane, the write blocks, the bridge stops draining the
// control socket, and the backpressure lands on the app -- where
// `PaneTapeFollowSubscriptions` already keeps one batch in flight and merges
// every append behind it into a single next fetch. The coalescing that makes a
// slow link cheap therefore stays in the one component that already implements
// it, and the bridge cannot grow a second, unbounded copy of it.
//
// The framer runs as an OBSERVER, not as a gate. Bytes are forwarded as they
// arrive rather than held until a record completes, which keeps the bound at one
// read buffer instead of one record -- and a record here can be the 16 MiB IPC
// line bound, since a D5 sync is sized against exactly that. A future repair
// policy that must act per record (T20 owns it: drop a slow subscriber forward
// to a fresh sync, or deliver a gap record) is the thing that would have to pay
// that cost, and it should pay it deliberately.
import DanTermProtocol
import Darwin
import Foundation

/// Proxies one accepted connection for its whole life, then reports.
///
/// It is a class with an explicit `run` rather than a pair of free functions
/// because the two directions share the metrics and the two descriptors, and
/// because closing one direction has to unblock the other.
final class BridgeConnection: @unchecked Sendable {
    /// One read buffer per direction is the bridge's entire memory bound. 64 KiB
    /// matches the relay this replaces, so a difference between them is the
    /// architecture and not the buffer size.
    private static let readBufferBytes = 64 * 1024

    /// How often a live connection reports its counters. The bridge is the only
    /// instrument that survives the phone leaving its network, so a connection
    /// that goes quiet has to be distinguishable from one that has died, and
    /// only a periodic line can do that.
    private static let reportInterval: TimeInterval = 5

    private let client: Int32
    private let upstream: Int32
    private let peer: String
    private let metrics = ConnectionMetrics()
    private let log: @Sendable (String) -> Void
    private let openLock = NSLock()
    private var isOpen = true

    init(client: Int32, upstream: Int32, peer: String, log: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.upstream = upstream
        self.peer = peer
        self.log = log
    }

    /// Runs both directions and returns when the conversation is over.
    ///
    /// The downlink runs on this thread and the uplink on its own, so the
    /// caller's thread is the one that outlives the connection and reports it.
    func run() {
        let reporter = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: Self.reportInterval)
                openLock.lock()
                let open = isOpen
                openLock.unlock()
                guard open else { return }
                log("\(peer) live | \(metrics.summary(final: false))")
            }
        }
        reporter.name = "t5-reporter"
        reporter.start()

        let uplinkThread = Thread { [self] in
            pump(
                from: client,
                to: upstream,
                direction: .uplink
            )
            // Half-close so a reply still in flight can drain instead of dying
            // mid-record.
            shutdown(upstream, SHUT_WR)
        }
        uplinkThread.name = "t5-uplink"
        uplinkThread.start()

        pump(from: upstream, to: client, direction: .downlink)
        shutdown(client, SHUT_WR)

        openLock.lock()
        isOpen = false
        openLock.unlock()
        log("\(peer) closed | \(metrics.summary(final: true))")
        Darwin.close(client)
        Darwin.close(upstream)
    }

    /// Reads one buffer, writes all of it, repeats. The absence of a queue here
    /// is the invariant, so nothing in this loop may start accumulating.
    private func pump(from source: Int32, to sink: Int32, direction: BridgeDirection) {
        var buffer = [UInt8](repeating: 0, count: Self.readBufferBytes)
        var framer = IpcLineFramer()
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(source, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                log("\(peer) \(direction) read failed: \(String(cString: strerror(errno)))")
                break
            }

            let forwarded = buffer.withUnsafeBytes { raw -> Bool in
                let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<count])
                let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                guard writeAll(chunk, to: sink) else { return false }
                let blocked = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started

                // Observation only, and deliberately after the write: measuring
                // must never delay the byte the user is waiting for.
                for event in framer.append(Data(chunk)) {
                    guard case .line(let line) = event else {
                        log("\(peer) \(direction) framer reported an oversized line")
                        continue
                    }
                    metrics.recordFrame(bytes: line.count, direction: direction)
                }
                if direction == .downlink {
                    metrics.recordDownlinkChunk(blockedNanoseconds: blocked, raw: chunk)
                }
                return true
            }
            if !forwarded { break }
        }
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer, to sink: Int32) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(sink, base.advanced(by: offset), bytes.count - offset)
            if written <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
