// macOS PTY allocation and posix_spawn recipe. This file owns only the
// synchronous launch mechanism; lifecycle ordering remains in TerminalPTYHost.
import Darwin
import PaneProcessLifecycle

/// The byte plane a host adopts, and the child identity behind it when there is one.
///
/// Identity is optional because owning a PTY and owning a child are separate facts: a
/// host can adopt a channel whose other end is held by something that is not a process
/// of ours. A host reading `nil` here installs no process source, signals no session,
/// and reaps no leader.
package struct SpawnedPTY: Sendable {
    package let master: Int32
    package let leader: pid_t?
    package let session: pid_t?

    package init(master: Int32, leader: pid_t?, session: pid_t?) {
        self.master = master
        self.leader = leader
        self.session = session
    }
}

/// Distinguishes a complete spawn from the reducer-facing classified failure.
package enum PTYSpawnOutcome: Sendable {
    case success(SpawnedPTY)
    case failure(SpawnFailure)
    /// The host abandoned the launch after a child existed, so the spawner closed
    /// the master, killed and reaped the child, and withheld any reducer outcome.
    case abandoned
}

/// Performs the blocking system launch. Both entry points are synchronous and
/// blocking by design: the caller owns getting off the pane's serial executor,
/// which `TerminalPTYHost` does with a dispatch hop rather than a Swift task, so
/// a launch still in its syscall at application exit parks no async frame.
enum PTYSpawner {
    /// `didLaunch` is called the instant a child exists, before the bootstrap
    /// handshake below. Returning `false` keeps ownership in the spawner, which
    /// closes the master, kills and reaps the child, and returns `.abandoned`.
    static func spawn(
        _ spec: PTYLaunchSpec,
        bootstrapExecutable: String,
        didLaunch: (SpawnedPTY) -> Bool = { _ in true }
    ) -> PTYSpawnOutcome {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = winsize(
            ws_row: UInt16(clamping: spec.initialDimensions.rows),
            ws_col: UInt16(clamping: spec.initialDimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, &name, nil, &size) == 0 else {
            return .failure(.systemError(errno))
        }
        defer {
            closeMaster(&master)
        }
        defer {
            if slave >= 0 { Darwin.close(slave) }
        }

        var statusPipe: [Int32] = [-1, -1]
        guard pipe(&statusPipe) == 0 else {
            return .failure(.systemError(errno))
        }
        defer {
            if statusPipe[0] >= 0 { Darwin.close(statusPipe[0]) }
            if statusPipe[1] >= 0 { Darwin.close(statusPipe[1]) }
        }
        guard fcntl(statusPipe[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(statusPipe[1], F_SETFD, FD_CLOEXEC) == 0
        else {
            let code = errno
            return .failure(.systemError(code))
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            return .failure(.systemError(actionsResult))
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            return .failure(.systemError(attributesResult))
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let slavePath = String(
            decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let actionResult = posix_spawn_file_actions_addinherit_np(&actions, statusPipe[1])
        guard actionResult == 0 else {
            return .failure(.systemError(actionResult))
        }
        let attributeResult = configureAttributes(&attributes)
        guard attributeResult == 0 else {
            return .failure(.systemError(attributeResult))
        }

        var leader: pid_t = 0
        let environment = spec.environment.map { "\($0.name)=\($0.value)" }
        let bootstrapArguments = [
            "PTYSessionBootstrap",
            String(statusPipe[1]),
            slavePath,
            spec.workingDirectory,
            spec.program,
        ] + spec.arguments
        let spawnResult = withMutableCStrings(bootstrapArguments) { arguments in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                withMutableCStrings(environment) { environment in
                    environment.withUnsafeMutableBufferPointer { environmentBuffer in
                        bootstrapExecutable.withCString { program in
                            posix_spawn(
                                &leader,
                                program,
                                &actions,
                                &attributes,
                                argumentBuffer.baseAddress,
                                environmentBuffer.baseAddress
                            )
                        }
                    }
                }
            }
        }
        guard spawnResult == 0 else {
            return .failure(.systemError(spawnResult))
        }
        Darwin.close(statusPipe[1])
        statusPipe[1] = -1
        guard didLaunch(SpawnedPTY(master: master, leader: leader, session: leader)) else {
            // Abandoned mid-launch. Released here because this is the only context
            // that still has the descriptors, and because the host that gave up on
            // this launch must not be made to wait on a reap to finish quiescing.
            closeMaster(&master)
            kill(leader, SIGKILL)
            _ = waitpid(leader, nil, 0)
            return .abandoned
        }
        let bootstrapFailure = readBootstrapFailure(statusPipe[0])
        Darwin.close(statusPipe[0])
        statusPipe[0] = -1
        if let bootstrapFailure {
            closeMaster(&master)
            _ = waitpid(leader, nil, 0)
            switch BootstrapStage(rawValue: bootstrapFailure.stage) {
            case .workingDirectory:
                return .failure(.workingDirectoryUnavailable)
            case .exec:
                return .failure(.executableUnavailable(bootstrapFailure.error))
            case nil:
                return .failure(.systemError(bootstrapFailure.error))
            }
        }

        let currentFlags = fcntl(master, F_GETFL)
        guard currentFlags >= 0,
              fcntl(master, F_SETFL, currentFlags | O_NONBLOCK) == 0
        else {
            let code = errno
            closeMaster(&master)
            kill(leader, SIGKILL)
            _ = waitpid(leader, nil, 0)
            return .failure(.systemError(code))
        }
        let ownedMaster = master
        master = -1
        return .success(SpawnedPTY(master: ownedMaster, leader: leader, session: leader))
    }

    static func discard(_ spawned: SpawnedPTY) {
        Darwin.close(spawned.master)
        guard let leader = spawned.leader else { return }
        kill(leader, SIGKILL)
        _ = waitpid(leader, nil, 0)
    }

    /// Closes the PTY master before reaping a spawned session leader. On macOS,
    /// the leader's exit drains its controlling terminal, so waiting while the
    /// parent still holds an unread master can deadlock both processes.
    private static func closeMaster(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private static func configureAttributes(_ attributes: inout posix_spawnattr_t?) -> Int32 {
        var defaults = sigset_t()
        var mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        let defaultResult = posix_spawnattr_setsigdefault(&attributes, &defaults)
        guard defaultResult == 0 else { return defaultResult }
        let maskResult = posix_spawnattr_setsigmask(&attributes, &mask)
        guard maskResult == 0 else { return maskResult }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        return posix_spawnattr_setflags(&attributes, flags)
    }

    /// Blocks until the bootstrap writes a complete failure payload or closes its
    /// status descriptor. Successful `execve` closes it through `FD_CLOEXEC`;
    /// bootstrap failure writes the payload and exits. If the bootstrap stalls
    /// before either, `InFlightLaunch.abandon` kills the leader, whose exit closes
    /// the descriptor and unblocks this read. Keep that abandonment coupling intact.
    private static func readBootstrapFailure(_ descriptor: Int32) -> BootstrapFailure? {
        var failure = BootstrapFailure(stage: 0, error: 0)
        var received = 0
        let expected = MemoryLayout<BootstrapFailure>.size
        while received < expected {
            let result = withUnsafeMutableBytes(of: &failure) { buffer in
                Darwin.read(descriptor, buffer.baseAddress?.advanced(by: received), expected - received)
            }
            if result > 0 {
                received += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return received == expected ? failure : nil
    }

    private static func withMutableCStrings<Result>(
        _ strings: [String],
        _ body: (inout [UnsafeMutablePointer<CChar>?]) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() { free(pointer) }
        }
        return body(&pointers)
    }
}

/// Binary status-pipe payload shared with the C bootstrap.
private struct BootstrapFailure {
    let stage: Int32
    let error: Int32
}

/// The two bootstrap stages the reducer can retry, each naming one candidate
/// ladder. The raw values are the `bootstrap_stage` enum in
/// `PTYSessionBootstrap/main.c`; every other stage is a terminal system error.
private enum BootstrapStage: Int32 {
    case workingDirectory = 8
    case exec = 9
}
