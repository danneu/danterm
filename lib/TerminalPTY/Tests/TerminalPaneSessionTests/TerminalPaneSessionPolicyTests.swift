// Pure fixtures for key encoding, grid sizing, and app-request launch assembly.
import PaneLifecycle
import Testing
@testable import TerminalPaneSession

/// Pins the pure policies the AppKit adapter will call without platform state.
struct TerminalPaneSessionPolicyTests {
    @Test("fixed special keys encode to their pinned byte sequences", arguments: [
        (TerminalInputKey.returnKey, [0x0D]),
        (.tab, [0x09]),
        (.backspace, [0x7F]),
        (.escape, [0x1B]),
        (.up, [0x1B, 0x5B, 0x41]),
        (.down, [0x1B, 0x5B, 0x42]),
        (.right, [0x1B, 0x5B, 0x43]),
        (.left, [0x1B, 0x5B, 0x44]),
        (.home, [0x1B, 0x5B, 0x48]),
        (.end, [0x1B, 0x5B, 0x46]),
        (.pageUp, [0x1B, 0x5B, 0x35, 0x7E]),
        (.pageDown, [0x1B, 0x5B, 0x36, 0x7E]),
        (.deleteForward, [0x1B, 0x5B, 0x33, 0x7E]),
    ] as [(TerminalInputKey, [UInt8])])
    func specialKeyEncoding(testCase: (TerminalInputKey, [UInt8])) {
        #expect(encodeTerminalKey(testCase.0, modifiers: []) == testCase.1)
    }

    @Test("Ctrl letters cover the full ASCII control range", arguments: Array(0..<26))
    func controlLetterEncoding(offset: Int) throws {
        let lowercase = try #require(Unicode.Scalar(97 + offset))
        let uppercase = try #require(Unicode.Scalar(65 + offset))

        #expect(encodeTerminalKey(.letter(lowercase), modifiers: .control) == [UInt8(offset + 1)])
        #expect(encodeTerminalKey(.letter(uppercase), modifiers: .control) == [UInt8(offset + 1)])
    }

    @Test("letters without Control and non-letters remain unmapped")
    func unmappedKeyEncoding() {
        #expect(encodeTerminalKey(.letter("a"), modifiers: []) == nil)
        #expect(encodeTerminalKey(.letter("1"), modifiers: .control) == nil)
        #expect(encodeTerminalKey(.returnKey, modifiers: .option) == [0x0D])
    }

    @Test("grid sizing floors each axis and clamps to terminal minima")
    func gridSizingFloorsAndClamps() {
        #expect(terminalGridDimensions(
            size: .init(width: 101, height: 55),
            cellSize: .init(width: 10, height: 12)
        ) == .init(columns: 10, rows: 4))
        #expect(terminalGridDimensions(
            size: .init(width: 1, height: 1),
            cellSize: .init(width: 10, height: 12)
        ) == .init(columns: 2, rows: 1))
    }

    @Test("grid sizing rejects degenerate and non-finite inputs", arguments: [
        (TerminalPointSize(width: 0, height: 10), TerminalPointSize(width: 1, height: 1)),
        (TerminalPointSize(width: 10, height: -1), TerminalPointSize(width: 1, height: 1)),
        (TerminalPointSize(width: 10, height: 10), TerminalPointSize(width: 0, height: 1)),
        (TerminalPointSize(width: .infinity, height: 10), TerminalPointSize(width: 1, height: 1)),
        (TerminalPointSize(width: 10, height: 10), TerminalPointSize(width: .nan, height: 1)),
    ])
    func gridSizingRejectsDegenerate(
        size: TerminalPointSize,
        cellSize: TerminalPointSize
    ) {
        #expect(terminalGridDimensions(size: size, cellSize: cellSize) == nil)
    }

    @Test("launch assembly preserves request layers and pins terminal identity")
    func launchAssembly() {
        let request = TerminalPaneLaunchRequest(
            workingDirectory: "/requested",
            command: "restored",
            launchCommand: "launch",
            restoreCommandBehavior: .execute,
            environment: [.init(name: "PANE", value: "pane")]
        )
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/requested", "/home", "/"],
            inheritedEnvironment: [.init(name: "BASE", value: "base")],
            terminalProgramVersion: "1.2.3"
        )

        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let input = configuration.launchInput

        #expect(configuration.initialDimensions == .init(columns: 80, rows: 24))
        #expect(input.initialDimensions == configuration.initialDimensions)
        #expect(input.requestedWorkingDirectory == "/requested")
        #expect(input.inheritedEnvironment == [.init(name: "BASE", value: "base")])
        #expect(input.advertisedEnvironment == [
            .init(name: "TERM", value: "xterm-256color"),
            .init(name: "COLORTERM", value: "truecolor"),
            .init(name: "TERM_PROGRAM", value: "DanTerm"),
            .init(name: "TERM_PROGRAM_VERSION", value: "1.2.3"),
        ])
        #expect(input.paneEnvironment == [.init(name: "PANE", value: "pane")])
        #expect(input.command == "restored")
        #expect(input.launchCommand == "launch")
        #expect(input.restoreCommandBehavior == .execute)
    }
}
