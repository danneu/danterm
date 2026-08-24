// Tests for the shared coding-agent registry and its total doctor-facts value.
import Testing

@testable import DanTermProtocol

@Suite struct AgentIntegrationTests {
    @Test("registry preserves the supported integration order and policies")
    func registryPreservesOrderAndPolicies() {
        #expect(AgentIntegration.allCases == [.claude, .codex])
        #expect(AgentIntegration.claude.rawValue == "claude")
        #expect(AgentIntegration.claude.displayName == "Claude")
        #expect(AgentIntegration.claude.doctorName == "Claude Code")
        #expect(AgentIntegration.claude.chipKind == .claude)
        #expect(AgentIntegration.claude.homePolicy.displayRoot == "~/.claude")
        #expect(AgentIntegration.claude.hookConfigDescription == "~/.claude/settings.json")
        #expect(AgentIntegration.claude.hookParseErrorDescription == "~/.claude/settings.json")
        #expect(AgentIntegration.claude.bundledSessionHookName == "danterm-claude-agent-session")
        #expect(AgentIntegration.claude.resumeCommand(sessionId: "session-1") == "claude --resume session-1")

        #expect(AgentIntegration.codex.rawValue == "codex")
        #expect(AgentIntegration.codex.displayName == "Codex")
        #expect(AgentIntegration.codex.doctorName == "Codex")
        #expect(AgentIntegration.codex.chipKind == .codex)
        #expect(AgentIntegration.codex.homePolicy.displayRoot == "$CODEX_HOME")
        #expect(AgentIntegration.codex.hookConfigDescription == "$CODEX_HOME/hooks.json or config.toml")
        #expect(AgentIntegration.codex.hookParseErrorDescription == "$CODEX_HOME/hooks.json")
        #expect(AgentIntegration.codex.bundledSessionHookName == "danterm-codex-agent-session")
        #expect(AgentIntegration.codex.resumeCommand(sessionId: "thread-1") == "codex resume thread-1")
    }

    @Test("doctor agent facts are total and iterate in registry order")
    func doctorAgentFactsAreTotalAndOrdered() {
        let facts = DoctorFacts.Agents { integration in
            DoctorFacts.Agent(
                present: integration == .claude,
                hooksParseError: nil,
                dantermHooks: [],
                skillInstalled: false,
                skillSearchPaths: []
            )
        }

        #expect(facts[.claude].present == true)
        #expect(facts[.codex].present == false)
        #expect(facts.ordered.map(\.integration) == AgentIntegration.allCases)
    }
}
