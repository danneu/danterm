// T5's measurement half: what the tailnet costs a real phone talking to a real
// pane through the T5 bridge, and what happens to that conversation when the
// phone changes networks.
//
// It deliberately drives no engine and presents no pixels. F7 already showed the
// composition works on this device, so rendering here would only add a variable
// to a latency number. What is under test is the transport and nothing else.
//
// The run has three phases, and they are separate because they answer different
// questions and must not be pooled:
//
//   A. RPC round trip -- `pane.info` out, its correlated reply back. This is the
//      network plus the bridge plus the app's own dispatch, with no PTY and no
//      shell in it. It is the floor: no interaction can be faster than this.
//   B. Echo round trip -- one keystroke up as `pane.input`, and the wait until
//      the pane's own echo of that keystroke arrives back as a tape feed event.
//      This is what the user actually feels, and it contains the shell.
//   C. Heartbeat -- one RPC per second, logged with its own wall clock, forever.
//      This is the mobility instrument: a wifi-to-cell switch shows up as a run
//      of stalled or failed beats and then either a recovery or a dead stream,
//      and only a continuous record can tell those apart.
import DanTermClient
import DanTermProtocol
import Darwin
import Foundation
import TerminalCoreRecording
import UIKit

/// Where the probe's own transcript goes, in the app's Documents container, so
/// it can be pulled off the device with `devicectl device copy from` afterwards.
///
/// This exists because the obvious instrument is not usable for the one
/// measurement T5 needs. `devicectl device process launch --console` streams the
/// console over the same LAN wifi the mobility test turns off: the first run of
/// this probe lost its log the instant wifi went down, and devicectl then
/// SIGTERMed the app, so the subject died with the instrument for a reason that
/// had nothing to do with the tailnet. A file on the phone survives both.
private let transcriptURL: URL? = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first?
    .appendingPathComponent("t5-beats.log")

private let transcriptLock = NSLock()

private func log(_ message: String) {
    print("SPIKE \(message)")
    fflush(stdout)
    guard let transcriptURL else { return }
    // Wall clock, not uptime: a reader correlating this against the Mac's bridge
    // log needs a timestamp both machines can be read against.
    let stamped = "\(Date().timeIntervalSince1970) \(message)\n"
    transcriptLock.lock()
    defer { transcriptLock.unlock() }
    if let handle = try? FileHandle(forWritingTo: transcriptURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(stamped.utf8))
    } else {
        try? Data(stamped.utf8).write(to: transcriptURL)
    }
}

/// Percentiles over whatever samples exist, printed with n first so an aggregate
/// can never be read as a measurement that did not happen.
private func report(_ label: String, _ samples: [Double]) {
    guard samples.isEmpty == false else {
        log("T5 BENCH \(label) n=0 NOT-MEASURED")
        return
    }
    let sorted = samples.sorted()
    func percentile(_ fraction: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
    log("T5 BENCH \(label) n=\(sorted.count)"
        + String(format: " p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms",
                 percentile(0.5), percentile(0.95), percentile(0.99), sorted[sorted.count - 1]))
}

/// Drives the whole probe on one thread.
///
/// One thread, and no inbox handing work to a display link, because every phase
/// here is request-then-wait: the thread that sends is the thread that must see
/// the answer, and interposing a queue would put its own scheduling into the
/// number being measured.
final class T5Probe: @unchecked Sendable {
    private let session: DanTermClientSession
    private let pane: String
    private let samplesPerPhase: Int
    private var assembler = PaneTapeSyncAssembler()
    private var syncApplied = false
    /// Set by the caller so a stalled or dead stream reaches the screen too, not
    /// only the console: a mobility run is watched on the device.
    var onStatus: (@Sendable (String) -> Void)?

    init(session: DanTermClientSession, pane: String, samplesPerPhase: Int) {
        self.session = session
        self.pane = pane
        self.samplesPerPhase = samplesPerPhase
    }

    private func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private func milliseconds(since start: UInt64) -> Double {
        Double(now() - start) / 1e6
    }

    func run() {
        do {
            try session.handshake()
            log("T5 handshake ok")
            try subscribe()
            try awaitSync()
            log("T5 sync applied; the replica position is exact and probing starts")
            status("T5: synchronized")

            var rpc: [Double] = []
            for _ in 0..<samplesPerPhase {
                if let sample = try rpcSample() { rpc.append(sample) }
            }
            report("rpc-round-trip (pane.info; network + bridge + app dispatch)", rpc)

            var echo: [Double] = []
            for index in 0..<samplesPerPhase {
                if let sample = try echoSample(index: index) { echo.append(sample) }
            }
            // Clear whatever the echo phase typed, so the pane is left as it was
            // found rather than holding a line of probe digits.
            _ = try send(
                method: .paneInput,
                params: ["pane": .string(pane), "text": .string("\u{15}")]
            )
            report("echo-round-trip (keystroke -> the pane's own echo; includes the shell)", echo)

            log("T5 PHASE-C heartbeat starting: one pane.info per second, forever."
                + " Switch the phone between wifi and cell now.")
            status("T5: heartbeat -- switch networks now")
            heartbeat()
        } catch {
            log("T5 FAIL \(error)")
            status("T5: failed -- \(error)")
        }
    }

    private func status(_ text: String) {
        onStatus?(text)
    }

    private func send(method: IpcRequestMethod, params: [String: JSONValue]) throws -> JSONValue {
        let id = JSONValue.string(UUID().uuidString)
        try session.send(JsonRpcRequest(id: id, method: method.rawValue, params: .object(params)))
        return id
    }

    private func subscribe() throws {
        _ = try send(method: .paneTape, params: [
            "pane": .string(pane),
            "follow": .bool(true),
            "start": .string("now"),
            "mode": .string(PaneTapeStreamMode.reconstructible.rawValue),
        ])
    }

    /// Reads until the opening sync completes.
    ///
    /// The probe waits for it rather than starting immediately because a D5 sync
    /// is a multi-record indivisible prefix, and measuring a round trip while a
    /// pane's whole history is still arriving would measure the sync's tail.
    private func awaitSync() throws {
        while syncApplied == false {
            guard let frame = try nextFrameTolerantOfTimeout() else { return }
            switch frame {
            case .response(let response):
                ingestTapeStart(response)
            case .notification(let method, let params):
                ingest(method: method, params: params)
            }
        }
    }

    /// The A phase: one request out, its correlated reply back.
    private func rpcSample() throws -> Double? {
        let started = now()
        let id = try send(method: .paneInfo, params: ["pane": .string(pane)])
        guard try pump(untilReply: id) != nil else { return nil }
        let sample = milliseconds(since: started)
        Thread.sleep(forTimeInterval: 0.05)
        return sample
    }

    /// The B phase: type one marker and wait for the pane to echo it back.
    ///
    /// The marker is three digits and unique per sample, so a match cannot be a
    /// stale one from an earlier iteration -- which is the whole reason this
    /// does not just type the same character every time.
    private func echoSample(index: Int) throws -> Double? {
        let marker = String(format: "%03d", index)
        let started = now()
        _ = try send(method: .paneInput, params: [
            "pane": .string(pane),
            "text": .string(marker),
        ])
        guard try pump(untilEcho: Array(marker.utf8)) else { return nil }
        let sample = milliseconds(since: started)
        Thread.sleep(forTimeInterval: 0.05)
        return sample
    }

    /// The C phase. Never returns: the run ends when the harness kills the app,
    /// so every beat is logged as it happens rather than summarized at the end.
    private func heartbeat() {
        var sequence = 0
        while true {
            sequence += 1
            let started = now()
            do {
                let id = try send(method: .paneInfo, params: ["pane": .string(pane)])
                guard try pump(untilReply: id) != nil else {
                    log("T5 BEAT seq=\(sequence) STREAM-CLOSED after"
                        + String(format: " %.1fms", milliseconds(since: started)))
                    status("T5: stream closed at beat \(sequence)")
                    return
                }
                let elapsed = milliseconds(since: started)
                // A beat that outlasts its own second is the interesting one: a
                // read timeout is retried rather than failed, so a network the
                // phone has left shows up here as a large round trip that
                // eventually completes, and a dead one shows up as a failure.
                log(String(format: "T5 BEAT seq=%d rtt=%.1fms ok", sequence, elapsed))
                status(String(format: "T5 beat %d: %.0fms", sequence, elapsed))
            } catch {
                log("T5 BEAT seq=\(sequence) FAILED after"
                    + String(format: " %.1fms", milliseconds(since: started))
                    + " error=\(error)")
                status("T5: beat \(sequence) failed -- \(error)")
                // T9 owns reconnect. A probe that silently reconnected would
                // hide exactly the event this phase exists to record, so the run
                // ends here and the console carries how it ended.
                return
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Reads frames until the awaited reply arrives, or until an echo matches, or
    /// until the stream ends. Every frame that is not the awaited one is still
    /// processed, so the tape subscription keeps advancing while a request is
    /// outstanding.
    ///
    /// Returns the matching response, or nil at end of stream.
    private func pump(untilReply id: JSONValue?) throws -> JsonRpcResponse? {
        while true {
            guard let frame = try nextFrameTolerantOfTimeout() else { return nil }
            switch frame {
            case .response(let response):
                ingestTapeStart(response)
                if let id, response.id == id { return response }
            case .notification(let method, let params):
                ingest(method: method, params: params)
            }
        }
    }

    /// The echo variant: returns true when a feed event carrying `marker` arrives.
    private func pump(untilEcho marker: [UInt8]) throws -> Bool {
        while true {
            guard let frame = try nextFrameTolerantOfTimeout() else { return false }
            switch frame {
            case .response(let response):
                ingestTapeStart(response)
            case .notification(let method, let params):
                if ingest(method: method, params: params, matching: marker) { return true }
            }
        }
    }

    /// A read timeout is not the end of the stream, so it is retried rather than
    /// propagated. Anything else is a real transport failure and passes through.
    private func nextFrameTolerantOfTimeout() throws -> DanTermClientFrame? {
        while true {
            do {
                return try session.nextFrame()
            } catch T23TCPTransport.Failure.timedOut {
                log("T5 read timed out with no bytes; still waiting")
                continue
            }
        }
    }

    private func ingestTapeStart(_ response: JsonRpcResponse) {
        guard let record = response.result.flatMap(decodePaneTapeRecord),
              case .start(let start) = record
        else { return }
        log("T5 start v\(start.version) \(start.columns)x\(start.rows)"
            + " syncPending=\(start.cursor == nil)")
    }

    @discardableResult
    private func ingest(
        method: String,
        params: JSONValue?,
        matching marker: [UInt8]? = nil
    ) -> Bool {
        guard let notification = PaneTapeEventNotification<JSONValue>(
                  method: method,
                  params: params
              ),
              let record = decodePaneTapeRecord(notification.record)
        else { return false }
        switch record {
        case .sync(let part):
            if assembler.ingest(part) != nil { syncApplied = true }
            return false
        case .event(let event):
            guard let marker,
                  let data = try? encodeIpcLine(event.event),
                  let decoded = try? JSONDecoder().decode(
                      NeutralTerminalRecordingEvent.self,
                      from: data
                  ),
                  case .feed(let bytes) = decoded
            else { return false }
            return contains(bytes, marker)
        case .end(let reason):
            log("T5 stream end \(reason.map(\.rawValue) ?? "unknown")")
            return false
        case .gap, .start, .unknown:
            return false
        }
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.isEmpty == false, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

/// The probe's shell: a black screen with one status line, because a mobility run
/// is watched on the device while the phone is off wifi and the console is not.
final class T5LatencyProbeViewController: UIViewController {
    private var label: UILabel?
    private var transport: T23TCPTransport?
    private var thread: Thread?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let label = UILabel(frame: CGRect(x: 12, y: 80, width: view.bounds.width - 24, height: 120))
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .green
        label.numberOfLines = 0
        label.text = "T5: starting"
        view.addSubview(label)
        self.label = label

        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["T5_HOST"],
              let rawPort = environment["T5_PORT"],
              let port = UInt16(rawPort),
              let pane = environment["T5_PANE"]
        else {
            log("T5 FAIL missing T5_HOST/T5_PORT/T5_PANE")
            label.text = "T5: missing environment"
            return
        }
        let samples = environment["T5_SAMPLES"].flatMap(Int.init) ?? 40
        // Start each run's transcript empty, so a pulled file is one run rather
        // than every run this build has ever done.
        if let transcriptURL { try? FileManager.default.removeItem(at: transcriptURL) }
        log("T5 transcript at \(transcriptURL?.path ?? "NONE")")

        do {
            // A read timeout, so a network the phone has left shows up as a
            // logged stall instead of a thread parked in read() forever.
            let transport = try T23TCPTransport(
                host: host,
                port: port,
                token: nil,
                readTimeoutSeconds: 10
            )
            self.transport = transport
            log("T5 connected to \(host):\(port) pane=\(pane) samplesPerPhase=\(samples)")
            let probe = T5Probe(
                session: DanTermClientSession(transport: transport),
                pane: pane,
                samplesPerPhase: samples
            )
            probe.onStatus = { [weak self] text in
                DispatchQueue.main.async { self?.label?.text = text }
            }
            let thread = Thread { probe.run() }
            thread.name = "t5-probe"
            thread.stackSize = 512 * 1024
            thread.start()
            self.thread = thread
        } catch {
            log("T5 FAIL transport: \(error)")
            label.text = "T5: transport failed -- \(error)"
        }
    }
}
