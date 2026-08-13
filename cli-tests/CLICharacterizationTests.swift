// Black-box characterization of the `danterm` executable against a scripted control
// endpoint: what it exits with, what it puts on stdout, and what it puts on stderr.
//
// These tests run the real binary as a subprocess and speak the control protocol at it
// over a real AF_UNIX socket, so nothing here links or reaches into the CLI's own
// transport code. That is the point: the same file must pass unchanged before and after
// the client transport is rewired, which is what makes it evidence that the CLI's
// observable surface did not move. Anything that needs to see inside the CLI belongs in
// one of the unit test files beside this one, not here.
import Foundation
import Testing
import Darwin
import DanTermProtocol

/// Locates the test bundle so the CLI executable beside it can be found. `Bundle.main`
/// under `swift test` points at the toolchain's test helper, not at the build products.
private final class BuildProductsAnchor: NSObject {}

/// One finished run of the `danterm` executable, as a caller of the shell would see it.
private struct CLIRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// A syntactically valid pane id. The parser rejects anything that is not a UUID before
/// the socket is touched, so a placeholder like "p1" would never reach an endpoint.
private let samplePaneId = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"

struct CLICharacterizationTests {
    @Test("no socket at the named path reports that DanTerm is not running")
    func missingSocketReportsNotRunning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let run = try runCLI(["ls"], socketPath: directory + "/absent.sock")

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: DanTerm is not running\n")
    }

    @Test("a socket file with nobody listening reports that DanTerm is not running")
    func refusedConnectionReportsNotRunning() throws {
        // Intent: a stale socket left behind by a dead instance reads the same as no
        //   socket at all.
        // Why it exists: ECONNREFUSED and ENOENT are different errno values, and only
        //   the CLI's own classification collapses them into one message.
        // Scenario: DanTerm crashed without unlinking its control socket.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/stale.sock"
        let listener = try boundSocket(at: path)
        Darwin.close(listener)

        let run = try runCLI(["ls"], socketPath: path)

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: DanTerm is not running\n")
    }

    @Test("an endpoint that never speaks reports that DanTerm is not responding")
    func silentEndpointReportsNotResponding() throws {
        // Intent: an accepted connection that sends nothing fails on the receive
        //   timeout rather than hanging forever.
        // Why it exists: this is the only path that distinguishes a wedged app from a
        //   missing one, and it is the one a rewrite most easily drops.
        // Scenario: DanTerm is running but its main thread is blocked.
        let run = try withScriptedEndpoint { connection in
            // Hold the connection open past the CLI's receive timeout without writing.
            Thread.sleep(forTimeInterval: 8)
            Darwin.close(connection)
        } run: { path in
            try runCLI(["ls"], socketPath: path)
        }

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: DanTerm is not responding\n")
    }

    @Test("a first line that is not a hello is rejected")
    func malformedHelloIsRejected() throws {
        let run = try withScriptedEndpoint { connection in
            writeLine(#"{"jsonrpc":"2.0","method":"something-else"}"#, to: connection)
            Darwin.close(connection)
        } run: { path in
            try runCLI(["ls"], socketPath: path)
        }

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: invalid hello from DanTerm\n")
    }

    @Test("a hello naming an unknown protocol version is rejected by number")
    func unsupportedProtocolVersionIsRejected() throws {
        let run = try withScriptedEndpoint { connection in
            writeLine(helloLine(protocolVersion: 2), to: connection)
            Darwin.close(connection)
        } run: { path in
            try runCLI(["ls"], socketPath: path)
        }

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: unsupported DanTerm IPC protocol 2\n")
    }

    @Test("an ordinary reply prints its result as one compact JSON line")
    func ordinaryReplyPrintsCompactJSON() throws {
        let result = JSONValue.object([
            "groups": .array([.object(["id": .string("g1")])]),
            "revision": .number(7),
        ])
        let run = try withScriptedEndpoint { connection in
            writeLine(helloLine(protocolVersion: 1), to: connection)
            guard let request = readLine(from: connection),
                  let id = requestId(of: request)
            else { Darwin.close(connection); return }
            writeLine(responseLine(id: id, result: result), to: connection)
            Darwin.close(connection)
        } run: { path in
            try runCLI(["ls"], socketPath: path)
        }

        #expect(run.status == 0)
        #expect(run.stderr == "")
        #expect(try jsonLines(run.stdout) == [result])
    }

    @Test("an error reply is printed on stderr with a failing exit status")
    func errorReplyIsReported() throws {
        let run = try withScriptedEndpoint { connection in
            writeLine(helloLine(protocolVersion: 1), to: connection)
            guard let request = readLine(from: connection),
                  let id = requestId(of: request)
            else { Darwin.close(connection); return }
            writeLine(errorResponseLine(id: id, message: "no such pane"), to: connection)
            Darwin.close(connection)
        } run: { path in
            try runCLI(["pane", "info", "--pane", samplePaneId], socketPath: path)
        }

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: no such pane\n")
    }

    @Test("a tape capture prints its start record and every event record as JSON lines")
    func tapeCapturePrintsRecordLines() throws {
        let start = JSONValue.object([
            "kind": .string("start"),
            "version": .number(Double(paneTapeStreamVersion)),
            "capture": .string("snapshot"),
            "format": .string("replay"),
            "provenance": .object(["pane": .string(samplePaneId)]),
            "initial": .object(["columns": .number(80), "rows": .number(24)]),
            "cursor": .object([
                "sequence": .number(0),
                "feedByteOffset": .number(0),
                "writeByteOffset": .number(0),
            ]),
        ])
        let event = JSONValue.object([
            "kind": .string("event"),
            "sequence": .number(0),
            "elapsedNanoseconds": .number(1000),
            "byteOffset": .number(0),
            "byteLength": .number(2),
            "event": .object(["feed": .string("aGk=")]),
        ])
        let end = JSONValue.object([
            "kind": .string("end"),
            "reason": .string("snapshot-complete"),
        ])

        let run = try withScriptedEndpoint { connection in
            writeLine(helloLine(protocolVersion: 1), to: connection)
            guard let request = readLine(from: connection),
                  let id = requestId(of: request)
            else { Darwin.close(connection); return }
            writeLine(responseLine(id: id, result: start), to: connection)
            writeLine(tapeNotificationLine(record: event), to: connection)
            writeLine(tapeNotificationLine(record: end), to: connection)
            Darwin.close(connection)
        } run: { path in
            try runCLI(["pane", "tape", "--pane", samplePaneId], socketPath: path)
        }

        #expect(run.status == 0)
        #expect(run.stderr == "")
        #expect(try jsonLines(run.stdout) == [start, event, end])
    }

    @Test("a parse error is reported before any socket is touched")
    func parseErrorNeedsNoEndpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let run = try runCLI(
            ["pane", "zoom", "--pane", samplePaneId, "sideways"],
            socketPath: directory + "/absent.sock"
        )

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: usage: danterm pane zoom --pane <pane-id> on|off|toggle\n")
    }
}

// MARK: - Running the executable

private func cliExecutableURL() -> URL {
    Bundle(for: BuildProductsAnchor.self)
        .bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("DanTermCLI")
}

private func runCLI(_ arguments: [String], socketPath: String) throws -> CLIRun {
    let process = Process()
    process.executableURL = cliExecutableURL()
    process.arguments = arguments
    process.environment = ["DANTERM_SOCK": socketPath, "PATH": "/usr/bin:/bin"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Read both pipes before waiting: a reply larger than one pipe buffer would
    // otherwise block the child on write while this thread blocks on exit.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIRun(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

// MARK: - The scripted endpoint

/// Binds a control socket, hands the accepted connection to `script` on a background
/// thread, and runs `run` against the socket path while the script plays out.
private func withScriptedEndpoint(
    script: @escaping @Sendable (Int32) -> Void,
    run: (String) throws -> CLIRun
) throws -> CLIRun {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/control.sock"
    let listener = try boundSocket(at: path)
    defer { Darwin.close(listener) }
    guard Darwin.listen(listener, 1) == 0 else {
        throw ScriptedEndpointError.listenFailed(errno)
    }

    let accepted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let connection = Darwin.accept(listener, nil, nil)
        accepted.signal()
        guard connection >= 0 else { return }
        script(connection)
    }

    let result = try run(path)
    // The script owns the connection and closes it; waiting on the accept alone keeps
    // the listener alive until there is nothing left to accept.
    _ = accepted.wait(timeout: .now() + 5)
    return result
}

private enum ScriptedEndpointError: Error {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case temporaryDirectoryFailed(Int32)
}

private func boundSocket(at path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ScriptedEndpointError.socketFailed(errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
            strncpy(buffer, source, capacity - 1)
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else {
        let failure = errno
        Darwin.close(fd)
        throw ScriptedEndpointError.bindFailed(failure)
    }
    return fd
}

private func temporaryDirectory() throws -> String {
    var template = Array((NSTemporaryDirectory() + "danterm-cli-XXXXXX").utf8CString)
    guard let made = mkdtemp(&template) else {
        throw ScriptedEndpointError.temporaryDirectoryFailed(errno)
    }
    return String(cString: made)
}

// MARK: - Speaking the protocol at the CLI

private func writeLine(_ line: String, to fd: Int32) {
    let data = Array((line + "\n").utf8)
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        }
        if written <= 0 {
            if written < 0 && errno == EINTR { continue }
            return
        }
        offset += written
    }
}

private func readLine(from fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var byte = UInt8(0)
    while true {
        let count = withUnsafeMutableBytes(of: &byte) { Darwin.read(fd, $0.baseAddress, 1) }
        if count == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(byte)
    }
}

private func helloLine(protocolVersion: Int) -> String {
    #"{"jsonrpc":"2.0","method":"\#(Methods.hello)","params":{"protocol":\#(protocolVersion)}}"#
}

private func requestId(of line: String) -> String? {
    let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: Data(line.utf8))
    return request?.id?.asString
}

private func responseLine(id: String, result: JSONValue) -> String {
    encoded(JsonRpcResponse(id: .string(id), result: result))
}

private func errorResponseLine(id: String, message: String) -> String {
    encoded(JsonRpcResponse(id: .string(id), error: JsonRpcError(code: -32602, message: message)))
}

private func tapeNotificationLine(record: JSONValue) -> String {
    encoded(JsonRpcRequest(
        method: Methods.paneTapeEvent,
        params: .object([
            "subscription": .string("s1"),
            "record": record,
        ])
    ))
}

private func encoded<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

/// Decodes stdout as JSON Lines, so a record's key order is not part of the assertion.
private func jsonLines(_ text: String) throws -> [JSONValue] {
    try text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
}
