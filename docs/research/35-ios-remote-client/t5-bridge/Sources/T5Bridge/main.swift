// The T5 bridge prototype: put the DanTerm control socket on the tailnet so a
// phone can hold a real conversation with a real pane.
//
// AUTHENTICATION, as the research doc's investigation rules require of anything
// that opens a listener. There is none, and that is the doc's own escape hatch
// rather than an omission: an unauthenticated listener is permitted exactly when
// it is bound to the tailnet interface. `TailnetBindAddress` is what makes that
// true by construction -- this process cannot be started on any other address,
// so there is no flag, no default, and no mistake that reaches a listener the
// tailnet does not already gate. Reaching it means holding a WireGuard key this
// tailnet has admitted.
//
// What that deliberately does NOT decide: pairing, certificate pinning, the
// method allowlist, rate limits, and the audit log. T6 records D4 and owns every
// one of them, and T6 must also weigh the ideal alternative to a bridge at all
// -- the app listening on the network itself. A prototype that grew an auth
// model would have pre-empted that comparison, so this one has no auth surface
// to argue about.
//
// It supersedes t23-relay.py, which took the authenticated branch with a shared
// token on a command line only because this Mac had no tailnet when F7 ran.
import DanTermProtocol
import Darwin
import Foundation

let usage = """
usage: t5-bridge --listen <tailnet-addr>:<port> --socket <control.sock>

  --listen  A Tailscale address on this machine (100.64.0.0/10) and a port.
            Wildcards and non-tailnet addresses are refused: this listener is
            unauthenticated and may exist only where the tailnet gates it.
  --socket  The DanTerm control socket to proxy onto that address.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("t5-bridge: \(message)\n".utf8))
    exit(2)
}

@Sendable func log(_ message: String) {
    print("bridge: \(message)")
    fflush(stdout)
}

var listenArgument: String?
var socketArgument: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--listen":
        guard let value = arguments.first else { fail("--listen needs a value\n\n\(usage)") }
        arguments.removeFirst()
        listenArgument = value
    case "--socket":
        guard let value = arguments.first else { fail("--socket needs a value\n\n\(usage)") }
        arguments.removeFirst()
        socketArgument = value
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown argument `\(flag)`\n\n\(usage)")
    }
}

guard let listenArgument, let socketArgument else {
    fail("--listen and --socket are both required\n\n\(usage)")
}

let bind: TailnetBindAddress
do {
    bind = try TailnetBindAddress.resolve(listenArgument)
} catch let rejection as TailnetBindAddress.Rejection {
    fail("refusing to listen: \(rejection)")
} catch {
    fail("refusing to listen: \(error)")
}

guard FileManager.default.fileExists(atPath: socketArgument) else {
    fail("no control socket at `\(socketArgument)`")
}

// A phone that vanishes mid-write must not take the process down; every write in
// the connection loop reports its own failure instead.
signal(SIGPIPE, SIG_IGN)

let listener = socket(AF_INET, SOCK_STREAM, 0)
guard listener >= 0 else { fail("socket(): \(String(cString: strerror(errno)))") }
var reuse: Int32 = 1
_ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = bind.port.bigEndian
guard inet_pton(AF_INET, bind.address, &address.sin_addr) == 1 else {
    fail("inet_pton refused `\(bind.address)`")
}

let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bound == 0 else { fail("bind(): \(String(cString: strerror(errno)))") }
guard Darwin.listen(listener, 4) == 0 else {
    fail("listen(): \(String(cString: strerror(errno)))")
}

log("listening on \(bind.address):\(bind.port) (interface \(bind.interfaceName))"
    + " -> \(socketArgument)")
log("unauthenticated by design: the tailnet is the gate, and no other bind"
    + " address is accepted")

while true {
    var peerAddress = sockaddr_in()
    var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let client = withUnsafeMutablePointer(to: &peerAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            accept(listener, $0, &peerLength)
        }
    }
    guard client >= 0 else {
        if errno == EINTR { continue }
        log("accept(): \(String(cString: strerror(errno)))")
        continue
    }

    var peerText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let peerHost = inet_ntop(AF_INET, &peerAddress.sin_addr, &peerText, socklen_t(peerText.count))
        .map { String(cString: $0) } ?? "?"
    let peer = "\(peerHost):\(UInt16(bigEndian: peerAddress.sin_port))"

    // Nagle off: the uplink is single keystrokes, and coalescing them into
    // 40ms batches would charge the interactive path for the bridge's
    // convenience. The downlink self-coalesces in the app already.
    var noDelay: Int32 = 1
    _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
    var noSignal: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

    let upstream = socket(AF_UNIX, SOCK_STREAM, 0)
    guard upstream >= 0 else {
        log("\(peer) refused: socket(): \(String(cString: strerror(errno)))")
        Darwin.close(client)
        continue
    }
    var upstreamAddress = sockaddr_un()
    upstreamAddress.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    upstreamAddress.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketArgument.utf8)
    let pathCapacity = MemoryLayout.size(ofValue: upstreamAddress.sun_path)
    guard pathBytes.count < pathCapacity else {
        fail("control socket path is too long for sockaddr_un")
    }
    withUnsafeMutableBytes(of: &upstreamAddress.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
    }
    let connected = withUnsafePointer(to: &upstreamAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        log("\(peer) refused: control socket: \(String(cString: strerror(errno)))")
        Darwin.close(client)
        Darwin.close(upstream)
        continue
    }

    log("\(peer) connected")
    let connection = BridgeConnection(
        client: client,
        upstream: upstream,
        peer: peer,
        log: log
    )
    let thread = Thread { connection.run() }
    thread.name = "t5-connection"
    thread.start()
}
