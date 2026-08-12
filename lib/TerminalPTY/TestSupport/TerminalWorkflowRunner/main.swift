// Opt-in real-PTY compatibility driver that records each application at the pane-session seam.
import Foundation
import Darwin
import PaneProcessLifecycle
import TerminalCore
import TerminalCoreRecording
import TerminalPaneSession
import TerminalPTYWaitSupport
import TerminalWorkflowSupport

/// Defines one independently captured application contract and its owning login shell.
private struct Workflow {
    let name: String
    let shell: String
    let steps: [Step]
}

/// Keeps workflow input and synchronization ordered through the pane-session owner.
private enum Step {
    case text(String)
    case key(TerminalInputKey, TerminalKeyModifiers = [])
    case resize(Int, Int)
    case expect(String)
    case expectFollowing(String, after: String)
    case expectFor(String, String)
}

/// Runs the opt-in compatibility matrix without exposing a reusable product API.
@main
private enum TerminalWorkflowRunner {
    @MainActor
    static func main() async {
        do {
            try await execute()
        } catch {
            FileHandle.standardError.write(Data("terminal workflows: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func execute() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw RunnerError.usage }
        let runDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let bootstrap = arguments[2]
        let home = ProcessInfo.processInfo.environment["HOME"] ?? runDirectory.appending(path: "home").path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

        let workflows = makeWorkflows(runDirectory: runDirectory)
        var failures: [String] = []
        for workflow in workflows {
            do {
                try await run(workflow, runDirectory: runDirectory, bootstrap: bootstrap, home: home, path: path)
            } catch {
                failures.append("\(workflow.name): \(error)")
            }
        }
        if failures.isEmpty == false {
            throw RunnerError.failed(failures.joined(separator: "; "))
        }
    }

    @MainActor
    private static func run(
        _ workflow: Workflow,
        runDirectory: URL,
        bootstrap: String,
        home: String,
        path: String
    ) async throws {
        let directory = runDirectory.appending(path: workflow.name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dimensions = TerminalDimensions(columns: 80, rows: 24)
        let environment = [
            EnvironmentEntry(name: "HOME", value: home),
            EnvironmentEntry(name: "PATH", value: path),
            EnvironmentEntry(name: "LANG", value: "en_US.UTF-8"),
            EnvironmentEntry(name: "LC_ALL", value: "en_US.UTF-8"),
            EnvironmentEntry(name: "DANTERM", value: "1"),
            EnvironmentEntry(name: "DANTERM_WORKFLOW_SSH_CONFIG", value: ProcessInfo.processInfo.environment["DANTERM_WORKFLOW_SSH_CONFIG"] ?? ""),
        ]
        let input = LaunchPolicyInput(
            accountShell: workflow.shell,
            executablePaths: [workflow.shell],
            requestedWorkingDirectory: home,
            homeDirectory: home,
            accessibleDirectories: [home],
            inheritedEnvironment: environment,
            advertisedEnvironment: [
                EnvironmentEntry(name: "TERM", value: "xterm-256color"),
                EnvironmentEntry(name: "COLORTERM", value: "truecolor"),
                EnvironmentEntry(name: "TERM_PROGRAM", value: "DanTerm"),
                EnvironmentEntry(name: "TERM_PROGRAM_VERSION", value: "workflow-test"),
            ],
            paneEnvironment: [],
            command: nil,
            launchCommand: nil,
            initialDimensions: dimensions
        )
        let controller = try TerminalPaneSessionController(
            configuration: .init(
                launchInput: input,
                terminalProgramVersion: "workflow-test"
            ),
            bootstrapExecutable: bootstrap,
            captureTransitions: true
        )
        var semanticEvents: [TerminalSemanticEvent] = []
        controller.onSemanticEvents = { semanticEvents.append(contentsOf: $0) }
        let terminationHandle = controller.terminationHandle

        var snapshots: [String] = []
        var failure: Error?
        do {
            for step in workflow.steps {
                switch step {
                // A scripted step has no originating system event to report.
                case .text(let text): controller.sendText(text, origin: nil)
                case .key(let key, let modifiers):
                    controller.sendKey(key, modifiers: modifiers, origin: nil)
                case .resize(let columns, let rows):
                    controller.setGridDimensions(.init(columns: columns, rows: rows))
                case .expect(let marker):
                    try await waitFor(marker, controller: controller)
                    controller.synchronizeState()
                    snapshots.append("marker=\(marker)\n\(controller.readViewportText())")
                case .expectFollowing(let marker, let anchor):
                    try await waitFor(marker, after: anchor, controller: controller)
                    controller.synchronizeState()
                    snapshots.append("marker=\(marker) after=\(anchor)\n\(controller.readViewportText())")
                case .expectFor(let expectedWorkflow, let marker):
                    if workflow.name == expectedWorkflow {
                        try await waitFor(marker, controller: controller)
                    }
                }
            }
        } catch {
            failure = error
            controller.synchronizeState()
            snapshots.append("failure=\(error)\n\(controller.readViewportText())")
        }

        let capture = controller.diagnosticCapture(test: "workflow-\(workflow.name)")
        semanticEvents.append(contentsOf: capture.semanticEvents)
        if failure == nil {
            do { try validateSemantics(workflow.name, events: semanticEvents) }
            catch { failure = error }
        }
        if workflow.name == "asciinema" {
            do {
                try validateAsciinemaPlayback(capture)
                let cast = directory.appending(path: "session.cast")
                let report = try AsciicastValidator.validate(Data(contentsOf: cast))
                try report.description.write(
                    to: directory.appending(path: "cast-validation.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                try? "status=failed\nerror=\(error)\n".write(
                    to: directory.appending(path: "cast-validation.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                if failure == nil { failure = error }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(capture.recording).write(to: directory.appending(path: "recording.json"))
        try snapshots.joined(separator: "\n---\n").write(to: directory.appending(path: "snapshots.txt"), atomically: true, encoding: .utf8)
        try semanticEvents.map(describe).joined(separator: "\n").write(to: directory.appending(path: "semantic-events.txt"), atomically: true, encoding: .utf8)
        let status = failure.map { "status=failed\nerror=\($0)\n" } ?? "status=passed\n"
        try status.write(to: directory.appending(path: "result.txt"), atomically: true, encoding: .utf8)
        controller.tearDown()
        // The record below is a claim that every resource was released, and only
        // quiescence supports it. A pane that never quiesces is this workflow's
        // failure to report, not a wait to sit in until something outside kills the
        // run -- and nothing outside would: the wrapper script imposes no timeout.
        let quiesced = await terminationHandle.quiesced(within: .seconds(30))
        if quiesced == false, failure == nil {
            failure = RunnerError.timeout("pane quiescence after teardown")
        }
        let state = quiesced ? "released" : "live"
        var ownership = "pane_session=\(state)\npty_owner=\(state)\ndescriptors=\(state)\nsources=\(state)\n"
        if workflow.name == "asciinema" {
            ownership += "recorder=\(state)\ninner_shell=\(state)\nforeground_job=\(state)\n"
        }
        try ownership.write(to: directory.appending(path: "ownership.txt"), atomically: true, encoding: .utf8)
        if let failure { throw failure }
    }

    @MainActor
    private static func waitFor(
        _ marker: String,
        controller: TerminalPaneSessionController
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            controller.synchronizeState()
            if controller.readFullHistoryText().contains(marker) { return }
            // Sleeping, not yielding: this wait shares a machine with the pane it is
            // waiting on, and a spin competes with the very work that ends it. A
            // cancelled sleep ends the wait rather than leaving the loop to sample on
            // with nothing pacing it.
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        throw RunnerError.timeout(marker)
    }

    @MainActor
    private static func waitFor(
        _ marker: String,
        after anchor: String,
        controller: TerminalPaneSessionController
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            controller.synchronizeState()
            let history = controller.readFullHistoryText()
            if let anchorRange = history.range(of: anchor, options: .backwards),
               history[anchorRange.upperBound...].contains(marker) { return }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        throw RunnerError.timeout("\(marker) after \(anchor)")
    }

    private static func describe(_ event: TerminalSemanticEvent) -> String {
        switch event {
        case .title(let value): "title=\(value)"
        case .workingDirectory(let value): "cwd=\(value ?? "")"
        case .bell: "bell"
        case .integrationReady: "integration-ready"
        case .commandStarted(let value): "command-start=\(value)"
        case .commandEnded(let exitStatus): "command-end=\(exitStatus)"
        case .connectionDeclared(.local): "connection=local"
        case .connectionDeclared(.remote(identity: nil)): "connection=remote"
        case .connectionDeclared(.remote(identity: let identity?)):
            "connection=remote:\(identity.user)@\(identity.host)"
        case let .desktopNotification(title, body): "notification=\(title):\(body)"
        case .progress(let state): "progress=\(String(describing: state))"
        }
    }

    private static func validateSemantics(
        _ workflow: String,
        events: [TerminalSemanticEvent]
    ) throws {
        if ["zsh", "bash", "fish"].contains(workflow) {
            guard events.contains(.integrationReady),
                  events.contains(where: { if case .commandStarted = $0 { true } else { false } }),
                  events.contains(where: { if case .commandEnded = $0 { true } else { false } }),
                  events.contains(where: { if case .workingDirectory = $0 { true } else { false } })
            else { throw RunnerError.missingSemantics(workflow) }
        }
        if workflow == "ssh" {
            guard events.contains(.connectionDeclared(.remote(identity: nil))),
                  events.contains(where: {
                      if case .connectionDeclared(.remote(identity: .some)) = $0 { true } else { false }
                  }),
                  events.contains(.connectionDeclared(.local)),
                  let interruptedCommand = events.firstIndex(where: {
                      if case .commandStarted(let command) = $0 {
                          command.contains("__SSH_%s_READY__")
                      } else {
                          false
                      }
                  }),
                  let interruptedRemote = events[events.index(after: interruptedCommand)...]
                      .firstIndex(of: .connectionDeclared(.remote(identity: nil))),
                  events[events.index(after: interruptedRemote)...]
                      .contains(.connectionDeclared(.local))
            else { throw RunnerError.missingSemantics(workflow) }
        }
    }

    private static func validateAsciinemaPlayback(_ capture: TerminalPaneDiagnosticCapture) throws {
        let feed = capture.recording.events.flatMap { event -> [UInt8] in
            if case .feed(let bytes) = event { return bytes }
            return []
        }
        let coloredMarker = Array("\u{1B}[36m__ASCIINEMA_UTF8__=café-λ\u{1B}[0m".utf8)
        var markerCount = 0
        if feed.count >= coloredMarker.count {
            for start in 0...(feed.count - coloredMarker.count) {
                if feed[start..<(start + coloredMarker.count)].elementsEqual(coloredMarker) {
                    markerCount += 1
                }
            }
        }
        guard markerCount >= 2
        else { throw RunnerError.invalidPlayback("colored marker did not appear in recording and playback") }
        guard capture.terminal.currentStyle == TerminalStyle(),
              capture.terminal.isAlternateScreenActive == false,
              capture.terminal.presentation.isCursorVisible,
              capture.terminal.presentation.cursorShape == .block,
              capture.terminal.presentation.isCursorBlinking == false,
              capture.terminal.presentation.isSynchronizedOutputActive == false
        else { throw RunnerError.invalidPlayback("terminal style or screen state was not restored") }
    }

    private static func makeWorkflows(runDirectory: URL) -> [Workflow] {
        let corpus = runDirectory.appending(path: "corpus.txt").path
        let sshConfig = runDirectory.appending(path: "ssh/config").path
        let integration = (ProcessInfo.processInfo.environment["DANTERM_REPO_ROOT"] ?? "") + "/integrations/shell-integration/danterm.zsh"
        let sshConfigArgument = shellQuote(sshConfig)
        let integrationArgument = shellQuote(integration)
        let remoteSSHCommand = shellQuote("source \(integrationArgument); printf '\\033[35m__SSH_UNICODE__=λ\\033[0m\\n__REMOTE_READY__\\n'; while read line; do stty size; test \"$line\" = exit && break; done")
        let remoteSSHInvocation = shellQuote("/bin/zsh -f -c \(remoteSSHCommand)")
        let interruptedSSHCommand = shellQuote("trap 'exit 130' INT; printf '__SSH_%s_READY__\\n' INTERRUPT; while :; do read -r line; done")
        let interruptedSSHInvocation = shellQuote("/bin/zsh -f -c \(interruptedSSHCommand)")
        let fzfArgument = shellQuote(ProcessInfo.processInfo.environment["DANTERM_FZF"] ?? "fzf")
        let asciinemaArgument = shellQuote(ProcessInfo.processInfo.environment["DANTERM_ASCIINEMA"] ?? "asciinema")
        let cast = runDirectory.appending(path: "asciinema/session.cast").path
        let shellSteps: [Step] = [
            .expect("DANTERM-WORKFLOW>"),
            .text("cd /; cd \"$HOME\"; printf '__CWD_OK__\\n'\n"), .expect("__CWD_OK__"),
            .expectFollowing("DANTERM-WORKFLOW>", after: "__CWD_OK__"),
            .text("printf '__PIPELINE__=WRONG\\n'; X "), .key(.left),
            .key(.backspace), .text("\n"), .expect("__PIPELINE__=WRONG"),
            .expectFollowing("DANTERM-WORKFLOW>", after: "__PIPELINE__=WRONG"),
            .text("printf '__UNICODE__=%s\\n' café/δ.txt\n"), .expect("__UNICODE__=café/δ.txt"),
            .text("printf '__TAB__=%s\\n' ~/caf"), .key(.tab), .text("δ"), .key(.tab),
            .text("\n"), .expect("__TAB__=\(runDirectory.appending(path: "home/café/δ.txt").path)"),
            .text("sh -c 'echo __FG_READY__; sleep 30'\n"), .expect("__FG_READY__"),
            .key(.character("z"), .control), .expect("DANTERM-WORKFLOW>"),
            .text("bg; jobs -p | sed 's/^/__JOB_PGID__=/'\n"), .expect("__JOB_PGID__="),
            .expectFollowing("DANTERM-WORKFLOW>", after: "__JOB_PGID__="),
            .text("fg\n"), .expectFor("fish", "to foreground"),
            .key(.character("c"), .control),
            .text("printf '__INTERRUPTED__\\n'\n"), .expect("__INTERRUPTED__"),
            .expectFollowing("DANTERM-WORKFLOW>", after: "__INTERRUPTED__"),
            .resize(47, 13), .text("stty size | sed 's/^/__SIZE__=/'\n"), .expect("__SIZE__=13 47"),
            .expectFollowing("DANTERM-WORKFLOW>", after: "__SIZE__=13 47"),
        ]
        return [
            Workflow(name: "zsh", shell: "/bin/zsh", steps: shellSteps),
            Workflow(name: "bash", shell: "/bin/bash", steps: shellSteps),
            Workflow(name: "fish", shell: ProcessInfo.processInfo.environment["DANTERM_FISH"] ?? "fish", steps: shellSteps),
            Workflow(name: "ssh", shell: "/bin/zsh", steps: [
                .expect("DANTERM-WORKFLOW>"), .text("ssh -tt -F \(sshConfigArgument) workflow-host \(remoteSSHInvocation); printf '__SSH_LOCAL__\\n'\n"),
                .expect("__SSH_UNICODE__=λ"), .expect("__REMOTE_READY__"),
                .resize(43, 12), .text("narrow\n"), .expect("12 43"),
                .resize(101, 37), .text("wide\n"), .expect("37 101"),
                .text("exit\n"), .expect("__SSH_LOCAL__"),
                .expectFollowing("DANTERM-WORKFLOW>", after: "__SSH_LOCAL__"),
                .text("ssh -tt -F \(sshConfigArgument) workflow-host \(interruptedSSHInvocation)\n"),
                .expect("__SSH_INTERRUPT_READY__"),
                .key(.character("c"), .control),
                .expectFollowing("DANTERM-WORKFLOW>", after: "__SSH_INTERRUPT_READY__"),
            ]),
            Workflow(name: "fzf", shell: "/bin/zsh", steps: [
                .expect("DANTERM-WORKFLOW>"), .text("printf 'alpha\\nβeta\\nβravo\\ngamma\\n' | \(fzfArgument) --layout=reverse --no-sort > /tmp/danterm-workflow-fzf-$PPID; printf '__FZF__='; cat /tmp/danterm-workflow-fzf-$PPID; rm /tmp/danterm-workflow-fzf-$PPID\n"),
                .expect("4/4"), .text("β"), .expect("2/4"), .resize(52, 16),
                .key(.down), .key(.returnKey), .expect("__FZF__=βravo"),
                .expectFollowing("DANTERM-WORKFLOW>", after: "__FZF__=βravo"),
            ]),
            Workflow(name: "more", shell: "/bin/zsh", steps: pagerSteps(command: "/usr/bin/more", corpus: corpus)),
            Workflow(name: "less", shell: "/bin/zsh", steps: pagerSteps(command: "/usr/bin/less", corpus: corpus)),
            Workflow(name: "asciinema", shell: "/bin/zsh", steps: [
                .expect("DANTERM-WORKFLOW>"),
                .text("SHELL=/bin/zsh TERM=xterm-256color \(asciinemaArgument) rec --stdin --overwrite --quiet --command /bin/zsh\\ -f \(shellQuote(cast))\n"),
                .expect("% "),
                .text("PS1='ASCIINEMA-INNER> '; PROMPT=\"$PS1\"; printf '\\033[36m__ASCIINEMA_UTF8__=café-λ\\033[0m\\n'\n"),
                .expect("__ASCIINEMA_UTF8__=café-λ"), .expect("ASCIINEMA-INNER>"),
                .text("sh -c 'echo __ASCIINEMA_JOB__; sleep 30'\n"), .expect("__ASCIINEMA_JOB__"),
                .key(.character("z"), .control), .expect("ASCIINEMA-INNER>"),
                .text("bg; printf '__ASCIINEMA_BG__\\n'\n"), .expect("__ASCIINEMA_BG__"),
                .text("fg\n"), .expectFollowing("sleep 30", after: "__ASCIINEMA_BG__"),
                .key(.character("c"), .control),
                .text("printf '__ASCIINEMA_INTERRUPTED__\\n'\n"), .expect("__ASCIINEMA_INTERRUPTED__"),
                .expectFollowing("ASCIINEMA-INNER>", after: "__ASCIINEMA_INTERRUPTED__"),
                .resize(53, 17), .text("stty size | sed 's/^/__ASCIINEMA_SIZE__=/'\n"),
                .expect("__ASCIINEMA_SIZE__=17 53"), .text("exit\n"),
                .expectFollowing("DANTERM-WORKFLOW>", after: "__ASCIINEMA_SIZE__=17 53"),
                .resize(80, 24),
                .text("printf '__ASCIINEMA_PLAYBACK_BEGIN__\\n'; \(asciinemaArgument) play --idle-time-limit 1 --speed 20 \(shellQuote(cast)); printf '__ASCIINEMA_PLAYBACK_DONE__\\n'\n"),
                .expectFollowing("__ASCIINEMA_UTF8__=café-λ", after: "__ASCIINEMA_PLAYBACK_BEGIN__"),
                .expect("__ASCIINEMA_PLAYBACK_DONE__"),
                .expectFollowing("DANTERM-WORKFLOW>", after: "__ASCIINEMA_PLAYBACK_DONE__"),
            ]),
        ]
    }

    private static func pagerSteps(command: String, corpus: String) -> [Step] {
        [
            .expect("DANTERM-WORKFLOW>"), .text("\(command) \(shellQuote(corpus)); printf '__PAGER_LOCAL__\\n'\n"),
            .text("/UNICODE-λ\n"), .expect("UNICODE-λ marker"),
            .key(.pageDown), .resize(49, 14), .key(.pageUp), .text("q"),
            .expect("__PAGER_LOCAL__"),
            .expectFollowing("DANTERM-WORKFLOW>", after: "__PAGER_LOCAL__"),
        ]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Classifies failures written beside the diagnostic capture for one durable run.
private enum RunnerError: Error, CustomStringConvertible {
    case usage
    case timeout(String)
    case failed(String)
    case missingSemantics(String)
    case invalidPlayback(String)

    var description: String {
        switch self {
        case .usage: "usage: TerminalWorkflowRunner RUN_DIRECTORY BOOTSTRAP"
        case .timeout(let marker): "timed out waiting for \(marker)"
        case .failed(let failures): failures
        case .missingSemantics(let workflow): "missing shell integration semantics for \(workflow)"
        case .invalidPlayback(let detail): "invalid asciinema playback: \(detail)"
        }
    }
}
