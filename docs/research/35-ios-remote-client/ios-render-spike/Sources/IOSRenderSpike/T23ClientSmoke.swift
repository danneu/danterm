// The T23 on-device integration smoke: link the shipped `DanTermClient` into an
// iOS binary, subscribe to a real pane on a live Mac, drive a replica
// `TerminalCore` from that pane's tape stream, and present it through the
// swapchain D2 selected.
//
// Every leg of this ran alone before and the composition never did, so what is
// under test here is the joining and nothing else. It is a smoke test: it fails
// or it passes, and it designs nothing. Deliberately absent, because each one
// belongs to a later task with its own decision: reconnect and resume (T9), any
// input surface beyond one canned line (T11), geometry negotiation (T10), and
// every part of the real client's shell.
//
// The transport in this file is spike scaffolding for the same reason the relay
// script is. `DanTermClient` ships only `UnixSocketTransport` and a phone cannot
// reach an AF_UNIX socket; the production network transport belongs to T5/T6
// with a real authentication story, so this one conforms to the seam locally
// and stays here.
import DanTermClient
import DanTermProtocol
import Darwin
import Foundation
import IOSurface
import TerminalCore
import TerminalCoreRecording
import TerminalRenderExecution
import TerminalRenderPlanning
import UIKit

// Same console convention as the rest of the spike: one prefixed line per fact,
// so a device launch's console is a transcript. main.swift's `log` is private to
// that file, and this one is private to this one.
private func log(_ message: String) {
    print("SPIKE \(message)")
    fflush(stdout)
}

/// A TCP conformance of `DanTermClientTransport`, which is the whole point of
/// the seam naming no socket kind: the conversation above it is unchanged.
///
/// `token` is optional because the two listeners this has spoken to authenticate
/// differently. The T23 relay took the authenticated branch -- a shared secret on
/// its first line -- only because the Mac had no tailnet then. The T5 bridge
/// binds a tailnet address instead, which is the research doc's own escape
/// hatch, so it wants no token line at all and would read one as a malformed
/// request. Passing nil is therefore a statement about which listener is on the
/// other end, not a way to skip a check.
///
/// Writes are serialized because the display link sends requests from the main
/// thread while the reader thread is blocked in `receive()`.
final class T23TCPTransport: DanTermClientTransport {
    enum Failure: Error {
        case unresolvedHost(String)
        case connectFailed(String)
        case writeFailed(String)
        case readFailed(String)
        /// The read timeout elapsed with no bytes. Distinct from `readFailed`
        /// because a stalled link is the thing T5 and T9 are trying to observe:
        /// a caller can log the stall and keep waiting, and a connection that is
        /// merely quiet must not be reported as a broken one.
        case timedOut
    }

    private let descriptor: Int32
    private let writeLock = NSLock()

    /// `readTimeoutSeconds` of 0 blocks forever, which is what a follower wants
    /// when nothing about mobility is being measured.
    init(host: String, port: UInt16, token: String?, readTimeoutSeconds: Int32 = 0) throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0,
              let first = resolved
        else { throw Failure.unresolvedHost(host) }
        defer { freeaddrinfo(resolved) }

        let socketDescriptor = socket(first.pointee.ai_family, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw Failure.connectFailed("socket()") }
        var noSignal: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard Darwin.connect(socketDescriptor, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0
        else {
            Darwin.close(socketDescriptor)
            throw Failure.connectFailed(String(cString: strerror(errno)))
        }
        if readTimeoutSeconds > 0 {
            var timeout = timeval(tv_sec: Int(readTimeoutSeconds), tv_usec: 0)
            _ = setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        // Single keystrokes go up this socket, so Nagle would batch exactly the
        // traffic whose latency is the product's headline number.
        var noDelay: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            IPPROTO_TCP,
            TCP_NODELAY,
            &noDelay,
            socklen_t(MemoryLayout<Int32>.size)
        )
        descriptor = socketDescriptor
        if let token, token.isEmpty == false {
            try send(Data("token \(token)\n".utf8))
        }
    }

    func send(_ bytes: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw Failure.writeFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    func receive() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return Data() }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timedOut }
                throw Failure.readFailed(String(cString: strerror(errno)))
            }
            return Data(chunk[0..<count])
        }
    }

    func close() {
        Darwin.close(descriptor)
    }
}

/// Non-background pixels in the surface the layer is showing, so "the Mac's pane
/// reached the phone's screen" is a number rather than a look at the device.
///
/// It reads the presented surface, not a copy: the question is what was
/// published, and the swapchain hands back the buffer it rendered into.
private func inkPixels(in surface: IOSurfaceRef) -> Int {
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    let stride = IOSurfaceGetBytesPerRow(surface)
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    let background = (bytes[0], bytes[1], bytes[2])
    var count = 0
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            if (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != background {
                count += 1
            }
        }
    }
    return count
}

/// A stable digest of what the replica is showing, so the Mac can diff the
/// phone's viewport against the source pane's own `pane read` without shipping
/// the text back over the wire.
///
/// Trailing spaces are stripped per row and trailing blank rows are dropped,
/// because a terminal pads a row to its width and `pane read` does not, and that
/// difference is not divergence.
private func viewportDigest(_ text: String) -> (digest: String, rows: Int) {
    var rows = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in String(line.reversed().drop { $0 == " " }.reversed()) }
    while rows.last?.isEmpty == true { rows.removeLast() }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Array(rows.joined(separator: "\n").utf8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return (String(format: "%016llx", hash), rows.count)
}

/// One thing the reader thread produces for the engine on the main thread.
///
/// The reader never touches the replica: it decodes, and hands over values. That
/// keeps the `Terminal` on one thread without a lock around it, and it makes the
/// display link the only thing that ever mutates engine state.
enum T23StreamItem: Sendable {
    /// Replaces the whole replica with exact state at a stated geometry.
    case synchronize(bytes: [UInt8], columns: Int, rows: Int)
    case event(NeutralTerminalRecordingEvent)
    /// A stream fact worth showing on the phone rather than only in the console.
    case note(String)
    case ended(String)
}

/// The hand-off between the reader thread and the display link.
final class T23StreamInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T23StreamItem] = []

    func append(_ item: T23StreamItem) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func drain() -> [T23StreamItem] {
        lock.lock()
        defer { lock.unlock() }
        let drained = items
        items.removeAll(keepingCapacity: true)
        return drained
    }
}

/// Reads one pane's tape stream over the client session and posts decoded items.
///
/// This runs on its own thread and blocks in `receive()`, which is why it owns
/// the session and the main thread only borrows it to send. It holds `inbox`
/// rather than the view controller so a torn-down controller cannot be messaged
/// from here.
final class T23StreamReader: @unchecked Sendable {
    private let inbox: T23StreamInbox
    let session: DanTermClientSession
    private let pane: String
    private var assembler = PaneTapeSyncAssembler()

    init(inbox: T23StreamInbox, session: DanTermClientSession, pane: String) {
        self.inbox = inbox
        self.session = session
        self.pane = pane
    }

    /// Subscribes and then reads until the stream ends. `start: now` with
    /// `mode: reconstructible` is the D5 join: the producer opens with an exact
    /// state sync rather than with whatever history it happens to still retain.
    func run() {
        do {
            try session.handshake()
            inbox.append(.note("handshake ok"))
            let tapeRequestId = JSONValue.string(UUID().uuidString)
            let request = JsonRpcRequest(
                id: tapeRequestId,
                method: IpcRequestMethod.paneTape.rawValue,
                params: .object([
                    "pane": .string(pane),
                    "follow": .bool(true),
                    "start": .string("now"),
                    "mode": .string(PaneTapeStreamMode.reconstructible.rawValue),
                ])
            )
            try session.send(request)

            while let frame = try session.nextFrame() {
                switch frame {
                case .response(let response):
                    // Correlate: the pane may be sent other requests from the
                    // main thread while this subscription streams, and their
                    // replies arrive here on the same conversation. Only the
                    // tape request's own reply is the start record.
                    guard response.id == tapeRequestId else {
                        inbox.append(.note(
                            "reply id=\(response.id.flatMap(\.asString) ?? "?")"
                                + " error=\(response.error?.message ?? "none")"
                        ))
                        continue
                    }
                    if let error = response.error {
                        inbox.append(.ended("rpc error: \(error.message)"))
                        return
                    }
                    guard let record = response.result.flatMap(decodePaneTapeRecord),
                          case .start(let start) = record
                    else {
                        inbox.append(.ended("malformed start record"))
                        return
                    }
                    inbox.append(.note(
                        "start v\(start.version) \(start.columns)x\(start.rows)"
                            + " reconstructible=\(start.reconstructible)"
                            + " syncPending=\(start.cursor == nil)"
                    ))
                case .notification(let method, let params):
                    guard let notification = PaneTapeStreamNotification(
                        method: method,
                        params: params
                    ) else { continue }
                    if handle(notification.record) == false { return }
                }
            }
            inbox.append(.ended("stream closed"))
        } catch {
            inbox.append(.ended("stream failed: \(error)"))
        }
    }

    /// Returns false when the stream is over.
    private func handle(_ value: JSONValue) -> Bool {
        guard let record = decodePaneTapeRecord(value) else {
            inbox.append(.note("undecodable record"))
            return true
        }
        switch record {
        case .start:
            return true
        case .gap(let gap):
            inbox.append(.note("gap loss=\(gap.droppedEventCount.map(String.init) ?? "total")"))
            return true
        case .sync(let part):
            // The assembler is the shipped one. A sync is indivisible, so state
            // is applied only when the completing part arrives.
            guard let state = assembler.ingest(part) else { return true }
            inbox.append(.synchronize(
                bytes: state.bytes,
                columns: state.columns,
                rows: state.rows
            ))
            inbox.append(.note("sync applied \(state.bytes.count)B at \(state.columns)x\(state.rows)"))
            return true
        case .event(let event):
            guard let data = try? encodeIpcLine(event.event),
                  let decoded = try? JSONDecoder().decode(
                      NeutralTerminalRecordingEvent.self,
                      from: data
                  )
            else {
                inbox.append(.note("undecodable event #\(event.sequence)"))
                return true
            }
            inbox.append(.event(decoded))
            return true
        case .end(let reason):
            inbox.append(.ended("end \(reason.map(\.rawValue) ?? "unknown")"))
            return false
        case .unknown(let kind):
            inbox.append(.note("unknown record kind \(kind)"))
            return true
        }
    }
}

/// Drives the replica engine and the swapchain from the stream.
///
/// Presentation is gated on damage, which F3 found matters more than the
/// presentation arm did: a 60Hz display link ticking through an idle in which
/// nothing changed was most of that spike's energy. The only work an idle tick
/// does here is drain an empty inbox and retry a pending publish.
final class T23ClientSmokeViewController: UIViewController {
    private let inbox = T23StreamInbox()
    private var reader: T23StreamReader?
    private var transport: T23TCPTransport?
    private var readerThread: Thread?

    private var terminal: Terminal?
    private var interactionState = TerminalInteractionState()
    private var metrics: TerminalRenderMetrics?
    private var swapchain: TerminalFrameSwapchain?
    private var panel: UIView?
    private var banner: UILabel?
    private var status: UILabel?
    private var displayLink: CADisplayLink?
    private var displayScale: CGFloat = 1

    private var columns = 0
    private var rows = 0
    private var appliedEvents = 0
    private var syncCount = 0
    private var publishedFrames = 0
    private var coalescedPublishes = 0
    private var idleTicks = 0
    private var retriedPresentations = 0
    private var ticksSinceReport = 0
    private var lastLoggedModes = ""
    /// The surface the layer is currently showing, kept so the report can count
    /// its ink. Retaining it also matches what the Mac view does: the store the
    /// layer shows must outlive the publish that produced it.
    private var presentedSurface: IOSurfaceRef?
    private var pane = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["T23_HOST"],
              let rawPort = environment["T23_PORT"],
              let port = UInt16(rawPort),
              let pane = environment["T23_PANE"]
        else {
            log("T23 FAIL missing T23_HOST/T23_PORT/T23_PANE")
            showBanner("T23: missing environment")
            return
        }
        // Absent against the T5 bridge, which authenticates by being reachable
        // only on the tailnet; present against the retired T23 relay.
        let token = environment["T23_TOKEN"]
        self.pane = pane

        displayScale = view.window?.screen.scale ?? UIScreen.main.scale
        guard let metrics = TerminalRenderMetrics(displayScale: displayScale, fontSize: 11) else {
            log("T23 FAIL TerminalRenderMetrics returned nil")
            return
        }
        self.metrics = metrics

        showBanner("T23: connecting to \(host):\(port)")
        let status = UILabel(frame: CGRect(x: 8, y: 84, width: view.bounds.width - 16, height: 14))
        status.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        status.textColor = .green
        view.addSubview(status)
        self.status = status

        // One tap sends a canned line to the real pane. This is not an input
        // surface -- T11 owns that -- it is the cheapest proof that the uplink
        // and the downlink are the same conversation.
        view.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(sendCannedInput))
        )

        do {
            let transport = try T23TCPTransport(host: host, port: port, token: token)
            self.transport = transport
            let reader = T23StreamReader(
                inbox: inbox,
                session: DanTermClientSession(transport: transport),
                pane: pane
            )
            self.reader = reader
            log("T23 transport connected to \(host):\(port)")
            let thread = Thread { reader.run() }
            thread.name = "t23-stream"
            thread.start()
            readerThread = thread
        } catch {
            log("T23 FAIL transport: \(error)")
            showBanner("T23: transport failed -- \(error)")
            return
        }

        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Ends the run: the display link stops ticking and the socket closes, which
    /// also unblocks the reader thread out of `receive()`.
    ///
    /// This is not a `deinit`. A display link added to the run loop retains its
    /// target, so this controller cannot be deallocated while it ticks, and this
    /// controller is the app's root for the process lifetime anyway. Teardown is
    /// therefore driven by the stream ending, not by deallocation.
    private func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        transport?.close()
        transport = nil
    }

    private func showBanner(_ text: String) {
        if banner == nil {
            let label = UILabel(frame: CGRect(x: 8, y: 64, width: view.bounds.width - 16, height: 16))
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = .yellow
            view.addSubview(label)
            banner = label
        }
        banner?.text = text
    }

    @objc private func sendCannedInput() {
        guard let reader else { return }
        let text = "echo hello from the phone\r"
        do {
            try reader.session.send(JsonRpcRequest(
                id: .string(UUID().uuidString),
                method: IpcRequestMethod.paneInput.rawValue,
                params: .object(["pane": .string(pane), "text": .string(text)])
            ))
            log("T23 sent pane.input")
        } catch {
            log("T23 pane.input failed: \(error)")
        }
    }

    @objc private func step() {
        let items = inbox.drain()
        if items.isEmpty {
            idleTicks += 1
        }
        for item in items {
            apply(item)
        }
        present()
        reportModeChange()
        // The app never exits on its own, so a run that is killed by the harness
        // would otherwise leave no verdict at all. Report on a clock instead of
        // only at end of stream.
        ticksSinceReport += 1
        if ticksSinceReport >= 300 {
            ticksSinceReport = 0
            report()
        }
    }

    private func apply(_ item: T23StreamItem) {
        switch item {
        case .note(let note):
            log("T23 \(note)")
            showBanner("T23: \(note)")
        case .ended(let reason):
            log("T23 STREAM ENDED \(reason)")
            showBanner("T23: ended -- \(reason)")
            report()
            teardown()
        case .synchronize(let bytes, let columns, let rows):
            // Exact state is a replacement, so it lands in a fresh engine of the
            // stated geometry rather than on top of whatever was there.
            guard var replacement = Terminal(columns: columns, rows: rows) else {
                log("T23 FAIL cannot build a \(columns)x\(rows) replica")
                return
            }
            replacement.feed(bytes)
            // A replica must not answer queries: only the engine owning the PTY
            // does, so whatever the state stream provoked is dropped here.
            _ = replacement.drainReplyBytes()
            _ = replacement.drainPendingClipboardWrite()
            terminal = replacement
            resizeSurfaces(columns: columns, rows: rows)
            syncCount += 1
        case .event(let event):
            guard terminal != nil else { return }
            switch event {
            case .feed(let bytes):
                terminal!.feed(bytes)
                _ = terminal!.drainReplyBytes()
                _ = terminal!.drainPendingClipboardWrite()
            case .write, .input, .paste, .focus, .checkpoint:
                break
            case .mouse(let mouse):
                _ = applyNeutralTerminalMouse(
                    mouse,
                    terminal: &terminal!,
                    interactionState: &interactionState
                )
            case .resize(let newColumns, let newRows):
                // Stream geometry is unconditional and authoritative (F4): the
                // replica follows it rather than rendering at its own size.
                terminal!.resize(columns: newColumns, rows: newRows)
                resizeSurfaces(columns: newColumns, rows: newRows)
                log("T23 resize -> \(newColumns)x\(newRows)")
            case .viewport(let navigation):
                switch navigation {
                case .byRows(let count): terminal!.scroll(byRows: count)
                case .toTopRow(let row): terminal!.scroll(toTopRow: row)
                case .toBottom: terminal!.scrollToBottom()
                }
            }
            appliedEvents += 1
        }
    }

    /// Rebuilds the swapchain and the panel for a new grid. A live swapchain
    /// never changes shape, so a geometry change is a replacement.
    private func resizeSurfaces(columns newColumns: Int, rows newRows: Int) {
        guard let metrics, newColumns != columns || newRows != rows else { return }
        columns = newColumns
        rows = newRows
        swapchain = TerminalFrameSwapchain(columns: columns, rows: rows, metrics: metrics)
        if swapchain == nil {
            log("T23 FAIL swapchain allocation for \(columns)x\(rows)")
        }
        panel?.removeFromSuperview()
        let pixelWidth = CGFloat(metrics.cellWidthPixels * columns) / displayScale
        let pixelHeight = CGFloat(metrics.cellHeightPixels * rows) / displayScale
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        surface.layer.contentsScale = displayScale
        surface.layer.magnificationFilter = .nearest
        // The pane keeps the Mac's grid, so the phone scales the whole frame to
        // fit rather than cropping it or renegotiating geometry, which is T10's
        // question and not this smoke's.
        let available = view.bounds.width - 8
        let fit = min(1, available / max(pixelWidth, 1))
        surface.layer.anchorPoint = .zero
        surface.layer.position = CGPoint(x: 4, y: 104)
        surface.transform = CGAffineTransform(scaleX: fit, y: fit)
        view.addSubview(surface)
        panel = surface
        log("T23 surfaces \(columns)x\(rows) fitScale=\(String(format: "%.3f", fit))")
    }

    private func present() {
        guard let swapchain else { return }
        guard var terminal else { return }
        let damage = terminal.drainDamage()
        self.terminal = terminal
        guard damage.isEmpty == false else {
            // The pending-presentation retry is part of the swapchain contract
            // D2 priced: a coalesced publish reaches the screen only if someone
            // tries again, and an idle stream will not do it for us.
            if swapchain.hasPendingPresentation, let store = swapchain.retryPendingPresentation() {
                panel?.layer.contents = store.ioSurface
                presentedSurface = store.ioSurface
                publishedFrames += 1
                retriedPresentations += 1
            }
            return
        }
        let presentation = terminal.presentation
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: presentation.isCursorVisible,
                cursorShape: presentation.cursorShape
            )
        )
        if let store = swapchain.publish(plan: plan, damage: damage) {
            panel?.layer.contents = store.ioSurface
            presentedSurface = store.ioSurface
            publishedFrames += 1
        } else {
            coalescedPublishes += 1
        }
        status?.text = "events=\(appliedEvents) syncs=\(syncCount)"
            + " frames=\(publishedFrames) coalesced=\(coalescedPublishes)"
    }

    /// Logs the replicated mode set whenever it changes.
    ///
    /// A periodic report samples on a clock and missed a whole `vim` session in
    /// one run, which would have read as "modes did not replicate". These are
    /// exactly the state F4 found a late joiner gets wrong, so whether they
    /// track the stream is a claim this smoke should not leave to sampling luck.
    private func reportModeChange() {
        guard let terminal else { return }
        let modes = terminal.inputModes
        let current = "applicationCursorKeys=\(modes.applicationCursorKeys)"
            + " bracketedPaste=\(modes.bracketedPaste)"
            + " mouseTracking=\(modes.mouseTracking)"
            + " alternateScreen=\(terminal.isAlternateScreenActive)"
        guard current != lastLoggedModes else { return }
        lastLoggedModes = current
        log("T23 MODES \(current)")
    }

    /// The smoke's verdict, in the console, so a run is readable without the
    /// screen. Every count is printed even when zero, because a zero here is a
    /// result and not an absence.
    private func report() {
        log("T23 REPORT syncs=\(syncCount) appliedEvents=\(appliedEvents)"
            + " publishedFrames=\(publishedFrames) coalescedPublishes=\(coalescedPublishes)"
            + " retriedPresentations=\(retriedPresentations)"
            + " idleTicks=\(idleTicks) grid=\(columns)x\(rows)")
        log("T23 REPORT-PIXELS ink=\(presentedSurface.map(inkPixels(in:)) ?? -1)"
            + " (non-background pixels in the surface the layer is showing)")
        if let terminal {
            let modes = terminal.inputModes
            log("T23 REPORT-MODES applicationCursorKeys=\(modes.applicationCursorKeys)"
                + " bracketedPaste=\(modes.bracketedPaste)"
                + " mouseTracking=\(modes.mouseTracking)"
                + " alternateScreen=\(terminal.isAlternateScreenActive)"
                + " totalRows=\(terminal.scrollProjection.totalRows)")
            let converged = viewportDigest(terminal.viewportText)
            log("T23 REPORT-DIGEST \(converged.digest) rows=\(converged.rows)")
            let text = terminal.viewportText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            log("T23 REPORT-VIEWPORT nonEmptyRows=\(text.count)")
            for line in text.suffix(6) {
                log("T23 VIEWPORT | \(line)")
            }
        } else {
            log("T23 REPORT-VIEWPORT no replica was ever built")
        }
    }
}
