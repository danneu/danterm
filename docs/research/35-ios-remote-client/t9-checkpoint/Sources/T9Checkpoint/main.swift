// Reads one pane-replica-checkpoint.plist pulled off the phone and reports the replica state it
// encodes: the resume cursor, scrollback depth, input modes, and a viewport digest comparable with
// the source pane's own `pane read`. Reporting only -- it never talks to a device or a socket.
import CryptoKit
import Foundation
import TerminalCore

struct Envelope: Decodable {
    let formatVersion: Int
    let stateBytes: Data
    let columns: Int
    let rows: Int
    let paneId: UUID
    let recorderLifetimeId: UUID
    let nextSequence: UInt64
    let feedBytesBeforeNextSequence: Int
    let writeBytesBeforeNextSequence: Int
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: t9-checkpoint <checkpoint.plist>\n".utf8))
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)

guard var terminal = Terminal(
    columns: envelope.columns,
    rows: envelope.rows,
    machineHostname: "t9"
) else {
    FileHandle.standardError.write(Data("cannot build terminal\n".utf8))
    exit(1)
}
terminal.feed(Array(envelope.stateBytes))
_ = terminal.drainReplyBytes()
_ = terminal.drainPendingClipboardWrite()

// The normalization F4 and F7 used, so a phone digest and a `pane read` digest are comparable.
let viewport = terminal.viewportText
var lines = viewport
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { String($0.reversed().drop { $0 == " " }.reversed()) }
while let last = lines.last, last.isEmpty { lines.removeLast() }
let normalized = lines.joined(separator: "\n")
let digest = SHA256.hash(data: Data(normalized.utf8))
    .prefix(8)
    .map { String(format: "%02x", $0) }
    .joined()

let projection = terminal.scrollProjection
let modes = terminal.inputModes
let presentation = terminal.presentation
var report: [String] = []
report.append("paneId=\(envelope.paneId)")
report.append("geometry=\(envelope.columns)x\(envelope.rows)")
report.append("stateBytes=\(envelope.stateBytes.count)")
report.append("recorderLifetimeId=\(envelope.recorderLifetimeId)")
report.append("nextSequence=\(envelope.nextSequence)")
report.append("feedBytesBeforeNextSequence=\(envelope.feedBytesBeforeNextSequence)")
report.append("writeBytesBeforeNextSequence=\(envelope.writeBytesBeforeNextSequence)")
report.append("totalRows=\(projection.totalRows)")
report.append("topRow=\(projection.topRow)")
report.append("isAlternateScreenActive=\(terminal.isAlternateScreenActive)")
report.append("applicationCursorKeys=\(modes.applicationCursorKeys)")
report.append("bracketedPaste=\(modes.bracketedPaste)")
report.append("mouseTracking=\(modes.mouseTracking)")
report.append("isCursorVisible=\(presentation.isCursorVisible)")
report.append("viewportDigest=\(digest)")
FileHandle.standardOutput.write(Data((report.joined(separator: "\n") + "\n").utf8))

if arguments.contains("--print-viewport") {
    FileHandle.standardOutput.write(Data(("--- viewport ---\n" + normalized + "\n").utf8))
}
