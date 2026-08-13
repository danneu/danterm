// T4 spike: a second macOS process that speaks the control-socket protocol directly, follows one
// pane's tape, and drives its own TerminalCore from the stream. It presents the result as text and
// as a planned frame, and prints a JSON report so a shell script can diff it against the source
// pane's own `pane read`. Throwaway evidence for docs/research/35-ios-remote-client; it is not
// wired into the app build or the test gate, and it deliberately holds no production concerns
// (no reconnect, no resume, no error recovery beyond reporting).
import Darwin
import Foundation
import DanTermProtocol
import TerminalCore
import TerminalCoreRecording
import TerminalRenderPlanning

struct Options {
    var socketPath = ""
    var pane = ""
    var fromNow = false
    var idleMilliseconds = 1500
    var maxSeconds = 120.0
    var machineHostname: String?
    var columnsOverride: Int?
    var rowsOverride: Int?
    var traceEvents = false
    var dropAfterEvents: Int?
    var reflowToColumns: Int?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("t4-thin-client: \(message)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard let value = arguments.first else { fail("\(flag) needs a value") }
        arguments.removeFirst()
        return value
    }
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--socket": options.socketPath = next(argument)
        case "--pane": options.pane = next(argument)
        case "--from-now": options.fromNow = true
        case "--idle-ms": options.idleMilliseconds = Int(next(argument)) ?? 1500
        case "--max-seconds": options.maxSeconds = Double(next(argument)) ?? 120
        case "--hostname": options.machineHostname = next(argument)
        case "--columns": options.columnsOverride = Int(next(argument))
        case "--rows": options.rowsOverride = Int(next(argument))
        case "--trace": options.traceEvents = true
        case "--drop-after-events": options.dropAfterEvents = Int(next(argument))
        case "--reflow-to-columns": options.reflowToColumns = Int(next(argument))
        default: fail("unknown flag \(argument)")
        }
    }
    guard options.socketPath.isEmpty == false, options.pane.isEmpty == false else {
        fail("--socket and --pane are required")
    }
    return options
}

/// Blocking line reader with a poll-based idle timeout, so the client can decide the stream has
/// gone quiet without closing it.
final class LineReader {
    private let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    enum Outcome {
        case line(String)
        case idle
        case eof
    }

    func read(timeoutMilliseconds: Int) -> Outcome {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return .line(String(decoding: line, as: UTF8.self))
            }
            var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = withUnsafeMutablePointer(to: &descriptors) {
                poll($0, 1, Int32(timeoutMilliseconds))
            }
            if ready == 0 { return .idle }
            if ready < 0 {
                if errno == EINTR { continue }
                return .eof
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return .eof }
            if count < 0 {
                if errno == EINTR { continue }
                return .eof
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

func connect(to path: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { fail("socket() failed") }
    var value: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLength else { fail("socket path too long") }
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            strncpy(destination, source, maxLength - 1)
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { fail("connect failed: \(String(cString: strerror(errno)))") }
    return descriptor
}

func write(_ data: Data, to descriptor: Int32) {
    var offset = 0
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        while offset < buffer.count {
            let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
            if written <= 0 {
                if errno == EINTR { continue }
                fail("write failed")
            }
            offset += written
        }
    }
}

let options = parseOptions()
let descriptor = connect(to: options.socketPath)
let reader = LineReader(descriptor: descriptor)

guard case .line(let helloLine) = reader.read(timeoutMilliseconds: 5000) else {
    fail("no hello from DanTerm")
}
let hello = try JSONDecoder().decode(JSONValue.self, from: Data(helloLine.utf8))
guard hello["method"]?.asString == Methods.hello else { fail("unexpected first line: \(helloLine)") }

let requestId = UUID().uuidString
var params: [String: JSONValue] = ["pane": .string(options.pane), "follow": .bool(true)]
if options.fromNow { params["fromNow"] = .bool(true) }
write(
    try encodeIpcLine(JsonRpcRequest(id: .string(requestId), method: IpcRequestMethod.paneTape.rawValue, params: .object(params))),
    to: descriptor
)

// --- stream state -------------------------------------------------------------------------

var startRecord: JSONValue?
var gapRecord: JSONValue?
var endReason: String?
var terminal: Terminal?
var interactionState = TerminalInteractionState()
var clientColumns = 0
var clientRows = 0
var eventCounts: [String: Int] = [:]
var resizeLog: [String] = []
var viewportLog: [String] = []
var appliedEventCount = 0
var lastSequence: UInt64?
var sequenceBreaks: [String] = []
var termination = "idle"

let decoder = JSONDecoder()
let deadline = Date().addingTimeInterval(options.maxSeconds)

func trace(_ message: String) {
    guard options.traceEvents else { return }
    FileHandle.standardError.write(Data("[t4] \(message)\n".utf8))
}

@MainActor
func apply(_ event: NeutralTerminalRecordingEvent) {
    guard terminal != nil else { return }
    switch event {
    case .feed(let bytes):
        terminal!.feed(bytes)
        _ = terminal!.drainReplyBytes()
        _ = terminal!.drainPendingClipboardWrite()
    case .write, .input, .paste, .focus:
        break
    case .mouse(let mouse):
        _ = applyNeutralTerminalMouse(mouse, terminal: &terminal!, interactionState: &interactionState)
    case .resize(let columns, let rows):
        resizeLog.append("\(clientColumns)x\(clientRows) -> \(columns)x\(rows)")
        clientColumns = columns
        clientRows = rows
        terminal!.resize(columns: columns, rows: rows)
    case .viewport(let navigation):
        switch navigation {
        case .byRows(let rows):
            viewportLog.append("byRows \(rows)")
            terminal!.scroll(byRows: rows)
        case .toTopRow(let row):
            viewportLog.append("toTopRow \(row)")
            terminal!.scroll(toTopRow: row)
        case .toBottom:
            viewportLog.append("toBottom")
            terminal!.scrollToBottom()
        }
    case .checkpoint:
        break
    }
    appliedEventCount += 1
}

streamLoop: while Date() < deadline {
    switch reader.read(timeoutMilliseconds: options.idleMilliseconds) {
    case .idle:
        if startRecord != nil { termination = "idle"; break streamLoop }
        continue
    case .eof:
        termination = "eof"
        break streamLoop
    case .line(let line):
        guard let envelope = try? decoder.decode(JSONValue.self, from: Data(line.utf8)) else { continue }
        if startRecord == nil, envelope["id"] == .string(requestId) {
            if let message = envelope["error"]?["message"]?.asString { fail("rpc error: \(message)") }
            guard let start = envelope["result"] else { fail("malformed start") }
            startRecord = start
            let columns = options.columnsOverride ?? Int(start["initial"]?["columns"]?.asNumber ?? 0)
            let rows = options.rowsOverride ?? Int(start["initial"]?["rows"]?.asNumber ?? 0)
            clientColumns = columns
            clientRows = rows
            guard let created = Terminal(
                columns: columns,
                rows: rows,
                machineHostname: options.machineHostname
            ) else { fail("cannot build a \(columns)x\(rows) terminal") }
            terminal = created
            trace("start capture=\(start["capture"]?.asString ?? "?") initial=\(columns)x\(rows)")
            continue
        }
        guard startRecord != nil,
              envelope["method"] == .string(Methods.paneTapeEvent),
              let record = envelope["params"]?["record"]
        else { continue }

        switch record["kind"]?.asString {
        case "gap":
            gapRecord = record
            trace("gap \(record)")
        case "end":
            endReason = record["reason"]?.asString
            termination = "end"
            break streamLoop
        case "event":
            if let sequence = record["sequence"]?.asNumber.map({ UInt64($0) }) {
                if let last = lastSequence, sequence != last + 1 {
                    sequenceBreaks.append("\(last) -> \(sequence)")
                }
                lastSequence = sequence
            }
            guard let payload = record["event"] else { continue }
            let type = payload["type"]?.asString ?? "?"
            eventCounts[type, default: 0] += 1
            trace("event #\(record["sequence"]?.asNumber.map { String(Int($0)) } ?? "?") \(type)")
            guard let data = try? encodeIpcLine(payload),
                  let event = try? decoder.decode(NeutralTerminalRecordingEvent.self, from: data)
            else {
                eventCounts["undecodable:\(type)", default: 0] += 1
                continue
            }
            apply(event)
            if let limit = options.dropAfterEvents, appliedEventCount >= limit {
                termination = "client-dropped-connection"
                break streamLoop
            }
        default:
            continue
        }
    }
}
if Date() >= deadline { termination = "max-seconds" }

// --- report -------------------------------------------------------------------------------

var report: [String: JSONValue] = [:]
report["termination"] = .string(termination)
report["endReason"] = endReason.map(JSONValue.string) ?? .null
report["start"] = startRecord ?? .null
report["gap"] = gapRecord ?? .null
report["appliedEvents"] = .number(Double(appliedEventCount))
report["eventCounts"] = .object(eventCounts.mapValues { .number(Double($0)) })
report["resizes"] = .array(resizeLog.map(JSONValue.string))
report["viewportNavigations"] = .array(viewportLog.map(JSONValue.string))
report["sequenceBreaks"] = .array(sequenceBreaks.map(JSONValue.string))
report["lastSequence"] = lastSequence.map { .number(Double($0)) } ?? .null

// A purely local resize, with no stream event behind it: this is what an "observe" client would
// do to fit the pane on a narrower screen without touching the source pane's PTY size.
if let columns = options.reflowToColumns, terminal != nil {
    report["reflowedFrom"] = .string("\(clientColumns)x\(clientRows)")
    terminal!.resize(columns: columns, rows: clientRows)
    clientColumns = columns
    report["reflowedTo"] = .string("\(clientColumns)x\(clientRows)")
}

if let terminal {
    let projection = terminal.scrollProjection
    var grid: [String: JSONValue] = [
        "columns": .number(Double(terminal.viewportColumnCount)),
        "rows": .number(Double(clientRows)),
        "totalRows": .number(Double(projection.totalRows)),
        "topRow": .number(Double(projection.topRow)),
        "isFollowing": .bool(projection.isFollowing),
        "isAlternateScreenActive": .bool(terminal.isAlternateScreenActive),
    ]
    if let cursor = terminal.cursorPlacement {
        grid["cursor"] = .object([
            "row": .number(Double(cursor.row)),
            "column": .number(Double(cursor.column)),
        ])
    } else {
        grid["cursor"] = .null
    }
    report["grid"] = .object(grid)
    report["viewportText"] = .string(terminal.viewportText)

    // The two mode projections a client needs but cannot derive from a tail of the stream:
    // presentation drives what it draws, inputModes drives how it encodes a keystroke.
    let presentation = terminal.presentation
    report["presentation"] = .object([
        "isCursorVisible": .bool(presentation.isCursorVisible),
        "cursorShape": .string(String(describing: presentation.cursorShape)),
        "isCursorBlinking": .bool(presentation.isCursorBlinking),
        "isSynchronizedOutputActive": .bool(presentation.isSynchronizedOutputActive),
    ])
    let inputModes = terminal.inputModes
    report["inputModes"] = .object([
        "applicationCursorKeys": .bool(inputModes.applicationCursorKeys),
        "applicationKeypad": .bool(inputModes.applicationKeypad),
        "lineFeedNewLine": .bool(inputModes.lineFeedNewLine),
        "focusReporting": .bool(inputModes.focusReporting),
        "bracketedPaste": .bool(inputModes.bracketedPaste),
        "mouseTracking": .string(String(describing: inputModes.mouseTracking)),
        "sgrMouseEncoding": .bool(inputModes.sgrMouseEncoding),
        "kittyKeyboardFlags": .number(Double(inputModes.kittyKeyboardFlags)),
    ])

    // Presentation: the client owns pixels through the same platform-neutral seam the Mac pane
    // uses, so planning a frame here is the part of "presents the result" that is not text.
    let plan = planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: presentation.isCursorVisible,
            cursorShape: presentation.cursorShape
        )
    )
    report["framePlan"] = .object([
        "columns": .number(Double(plan.columns)),
        "rows": .number(Double(plan.rows)),
        "textRuns": .number(Double(plan.textRuns.count)),
        "backgroundRuns": .number(Double(plan.backgroundRuns.count)),
        "hasCursor": .bool(plan.cursor != nil),
    ])
}

FileHandle.standardOutput.write(try encodeIpcLine(JSONValue.object(report)))
Darwin.close(descriptor)
