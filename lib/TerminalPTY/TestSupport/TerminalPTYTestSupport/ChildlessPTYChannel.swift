// A real PTY whose child end a test holds, so a host can be driven across a real master
// descriptor with no child process anywhere.
//
// This is a fixture for who holds the other end, not a transport of its own. The host
// keeps its own read, write, and ioctl calls on the master, and nothing here stands in
// for a read turn, backpressure, or a reply path. Anything that fakes the host's byte
// path instead of feeding it belongs nowhere in this package.
import Darwin
import PaneProcessLifecycle
import Synchronization
import TerminalPTYHost

/// A PTY pair whose child end the test plays directly, adopted by a host as its channel.
///
/// Injected as the host's spawner, it hands over an already-open master and reports no
/// leader and no session, so the host owns a byte plane with no child. The test writes
/// the bytes a child would print, reads back what the host transmitted, and closes the
/// child end to produce the real end-of-output edge.
///
/// The child end is opened raw, so the line discipline neither echoes what the host
/// writes nor rewrites what either side sends: every byte asserted on is a byte that
/// crossed the descriptor unchanged.
///
/// Drive the child end from the test's own thread. The host owns the master and runs on
/// its own queue, but the three child-end calls here are not ordered against each other.
package final class ChildlessPTYChannel: TerminalPTYSpawning {
    /// The pair could not be opened, which leaves the test with nothing to drive.
    package enum Failure: Error {
        case openFailed(Int32)
    }

    /// The two descriptors and who owns them, kept together so ownership and closure
    /// are decided in one transaction rather than across two independent fields.
    private struct Ends: Sendable {
        var master: Int32
        var child: Int32
        /// Set once a host has taken the master, after which the host owns closing it.
        var adopted = false
        var receivedFromHost: [UInt8] = []
    }

    private let ends: Mutex<Ends>

    /// Opens the pair at the dimensions the host under test is built with, so a later
    /// resize is a change the test can see rather than the first size ever set.
    package init(initialDimensions: TerminalDimensions = .init(columns: 80, rows: 24)) throws {
        var master: Int32 = -1
        var child: Int32 = -1
        var settings = termios()
        cfmakeraw(&settings)
        var size = winsize(
            ws_row: UInt16(clamping: initialDimensions.rows),
            ws_col: UInt16(clamping: initialDimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &child, nil, &settings, &size) == 0 else {
            throw Failure.openFailed(errno)
        }
        // Both ends nonblocking, for the reason production makes the master nonblocking:
        // neither side may park a thread waiting on the other to drain.
        for descriptor in [master, child] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                let code = errno
                Darwin.close(master)
                Darwin.close(child)
                throw Failure.openFailed(code)
            }
        }
        ends = Mutex(Ends(master: master, child: child))
    }

    deinit {
        closeChildEnd()
        ends.withLock { ends in
            // The master belongs to the host from adoption on. Closing it here would
            // pull a descriptor out from under a live read source.
            if ends.adopted == false, ends.master >= 0 { Darwin.close(ends.master) }
            ends.master = -1
        }
    }

    // TerminalPTYSpawning: the host's blocking launch step, which here launches nothing
    // and hands over the master this channel already holds.
    package func spawn(
        _ spec: PTYLaunchSpec,
        bootstrapExecutable: String,
        didLaunch: (SpawnedPTY) -> Bool
    ) -> PTYSpawnOutcome {
        let master = ends.withLock { $0.master }
        guard master >= 0 else { return .failure(.systemError(EBADF)) }
        guard didLaunch(SpawnedPTY(master: master, leader: nil, session: nil)) else {
            // Abandoned mid-launch. The spawner owns the descriptors until the host
            // takes them, so the master is released here exactly as PTYSpawner does.
            ends.withLock { ends in
                if ends.master >= 0 { Darwin.close(ends.master) }
                ends.master = -1
            }
            return .abandoned
        }
        ends.withLock { $0.adopted = true }
        return .success(SpawnedPTY(master: master, leader: nil, session: nil))
    }

    // TerminalPTYSpawning: nothing here delays owner delivery.
    package func waitForDeliveryPermission() {}

    /// Writes the bytes a child would print, for the host to take through its own read
    /// source. Reports whether every byte reached the descriptor before the bound.
    @discardableResult
    package func writeFromChild(_ bytes: [UInt8], within limit: Duration = .seconds(20)) -> Bool {
        let child = ends.withLock { $0.child }
        guard child >= 0 else { return false }
        let deadline = ContinuousClock.now + limit
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(child, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            let code = errno
            if written < 0, code == EINTR { continue }
            // The host has not drained its end yet. That is ordinary backpressure on a
            // real PTY, so wait it out rather than reporting a write failure.
            guard written < 0, code == EAGAIN, ContinuousClock.now < deadline else { return false }
            usleep(1000)
        }
        return true
    }

    /// Everything the host has transmitted so far, read back at the child end.
    ///
    /// Drains what is available and accumulates it, so a poll may call this repeatedly
    /// and still see the whole transmission rather than only its last chunk.
    package func bytesReceivedFromHost() -> [UInt8] {
        let child = ends.withLock { $0.child }
        guard child >= 0 else { return ends.withLock { $0.receivedFromHost } }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(child, $0.baseAddress, $0.count)
            }
            if result > 0 {
                let chunk = Array(buffer.prefix(result))
                ends.withLock { $0.receivedFromHost.append(contentsOf: chunk) }
                continue
            }
            if result < 0, errno == EINTR { continue }
            break
        }
        return ends.withLock { $0.receivedFromHost }
    }

    /// The window size the host last pushed to the descriptor, read at the child end.
    package func childWindowSize() -> winsize? {
        let child = ends.withLock { $0.child }
        guard child >= 0 else { return nil }
        var size = winsize()
        guard ioctl(child, TIOCGWINSZ, &size) == 0 else { return nil }
        return size
    }

    /// Closes the child end, which is the host's real end-of-output edge.
    package func closeChildEnd() {
        let child = ends.withLock { ends -> Int32 in
            let descriptor = ends.child
            ends.child = -1
            return descriptor
        }
        guard child >= 0 else { return }
        Darwin.close(child)
    }
}
