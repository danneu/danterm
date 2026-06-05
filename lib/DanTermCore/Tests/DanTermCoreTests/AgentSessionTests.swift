// Tests for the pure agent-session value and catalog: validation, toolbar labels,
// recovery messages, and known-kind resume command construction.
import Foundation
import Testing

@testable import DanTermCore

struct AgentSessionTests {
    @Test("agent session normalizes kind and builds Claude display strings")
    func normalizesKindAndBuildsClaudeStrings() throws {
        // Intent: the validated constructor lowercases the kind, while the
        //   catalog supplies Claude's display name and resume command.
        // Why it exists: pins the one safe conversion from untrusted hook/restore
        //   strings into terminal-visible text.
        // Scenario: Claude reports a UUID-like session id with mixed-case kind.
        let session = try #require(AgentSession(kind: "Claude", sessionId: "4f3a2b1c-0000-4000-9000-abcdef123456"))

        #expect(session.kind == "claude")
        #expect(session.sessionId == "4f3a2b1c-0000-4000-9000-abcdef123456")
        #expect(session.toolbarLabel == "claude")
        #expect(AgentCatalog.resumeCommand(for: session) == "claude -r 4f3a2b1c-0000-4000-9000-abcdef123456")
        #expect(session.recoveryMessage == "[DanTerm] You were inside Claude session 4f3a2b1c-0000-4000-9000-abcdef123456 -- resume with: claude -r 4f3a2b1c-0000-4000-9000-abcdef123456")
    }

    @Test("agent catalog supports Codex resume command")
    func supportsCodexResumeCommand() throws {
        let session = try #require(AgentSession(kind: "codex", sessionId: "thread_1234abcd"))

        #expect(session.toolbarLabel == "codex")
        #expect(AgentCatalog.resumeCommand(for: session) == "codex resume thread_1234abcd")
        #expect(session.recoveryMessage == "[DanTerm] You were inside Codex session thread_1234abcd -- resume with: codex resume thread_1234abcd")
    }

    @Test("unknown agent kind has display text but no resume command")
    func unknownKindHasNoResumeCommand() throws {
        let session = try #require(AgentSession(kind: "future_agent", sessionId: "abc123"))

        #expect(AgentCatalog.displayName(for: session.kind) == "Future_Agent")
        #expect(AgentCatalog.resumeCommand(for: session) == nil)
        #expect(session.toolbarLabel == "future…")
        #expect(session.recoveryMessage == "[DanTerm] You were inside a Future_Agent session abc123")
    }

    @Test("toolbar label truncates long agent kinds")
    func toolbarLabelTruncatesLongKinds() throws {
        let session = try #require(AgentSession(kind: "claudedaksfjadsfsakfsjdfa", sessionId: "abc123"))

        #expect(session.toolbarLabel == "claude…")
        #expect(session.toolbarLabel.count == 7)
    }

    @Test("agent session rejects unsafe session ids", arguments: [
        "",
        String(repeating: "a", count: 129),
        "bad id",
        "bad;id",
        "bad'id",
        "bad`id",
        "bad$id",
        "bad&id",
        "bad|id",
        "-x",
        "--dangerously-skip-permissions",
        "bad\u{001B}id",
    ])
    func rejectsUnsafeSessionIds(_ sessionId: String) {
        #expect(AgentSession(kind: "claude", sessionId: sessionId) == nil)
    }

    @Test("agent session rejects unsafe kinds", arguments: [
        "",
        "-claude",
        "claude!",
        "claude code",
        String(repeating: "a", count: 33),
    ])
    func rejectsUnsafeKinds(_ kind: String) {
        #expect(AgentSession(kind: kind, sessionId: "4f3a2b1c") == nil)
    }

    @Test("agent session accepts shell-token-safe id characters")
    func acceptsShellTokenSafeIdCharacters() throws {
        let session = try #require(AgentSession(kind: "codex_cli", sessionId: "A.z:_@+-0123456789"))

        #expect(session.kind == "codex_cli")
        #expect(session.sessionId == "A.z:_@+-0123456789")
    }
}
