// Validates DanTerm's public terminal contract against both pinned terminfo baselines.
import Foundation
import Testing

@testable import TerminalCore

/// Keeps the public manifest synchronized with its normalized fixtures and executable evidence.
struct TerminalCapabilityManifestTests {
    @Test("capability manifest is versioned, unique, and backed by both pinned fixtures")
    func manifestContract() throws {
        let root = repositoryRoot()
        let manifest = try decode(
            CapabilityManifest.self,
            at: root.appending(path: "terminal-capabilities-v1.json")
        )

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.artifact == "terminal-capabilities-v1.json")
        #expect(manifest.terminalIdentity == "xterm-256color")
        #expect(Set(manifest.baselines.map(\.id)) == ["macos-26-ncurses-6.0", "ncurses-1.1261"])
        #expect(Set(manifest.environment.map(\.name)) == [
            "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
            "DANTERM", "DANTERM_SOCK", "DANTERM_PANE", "DANTERM_TOKEN",
            "LC_DANTERM_TOKEN", "DANTERM_RESTORE_SCROLLBACK_FILE",
        ])
        #expect(Set(manifest.environment.map(\.name)).count == manifest.environment.count)
        #expect(manifest.environment.first { $0.name == "TERM" }?.value == "xterm-256color")
        #expect(manifest.environment.first { $0.name == "COLORTERM" }?.value == "truecolor")
        #expect(manifest.environment.first { $0.name == "TERM_PROGRAM" }?.value == "DanTerm")
        #expect(manifest.environment.first { $0.name == "DANTERM_TOKEN" }?.visibility == "private")
        #expect(manifest.environment.first { $0.name == "LC_DANTERM_TOKEN" }?.visibility == "private")
        #expect(manifest.environment.first { $0.name == "DANTERM_RESTORE_SCROLLBACK_FILE" }?.ownership == "pane-when-restoring")
        #expect(Set(manifest.claims.map(\.id)).count == manifest.claims.count)
        #expect(Set(manifest.protocols.supported.map(\.id)).count == manifest.protocols.supported.count)
        #expect(Set(manifest.limits.map(\.id)).count == manifest.limits.count)
        #expect(manifest.limits.allSatisfy { $0.value > 0 && ["bytes", "events"].contains($0.unit) })
        #expect(Set(manifest.protocols.denied) == [
            "audible-bell", "clipboard-read", "da2", "decrqss", "kitty-osc-99",
            "osc-133", "sixel", "xtgettcap", "eight-bit-replies",
        ])

        let fixtures = try Dictionary(uniqueKeysWithValues: manifest.baselines.map { baseline in
            let fixture = try decode(
                TerminfoFixture.self,
                at: root.appending(path: baseline.fixture)
            )
            #expect(fixture.id == baseline.id)
            #expect(fixture.terminal == manifest.terminalIdentity)
            #expect(fixture.provenance == baseline.provenance)
            return (fixture.id, fixture)
        })

        for claim in manifest.claims {
            #expect(claim.evidence.isEmpty == false)
            #expect(Set(claim.variants.map(\.baselines)).flatMap { $0 }.isEmpty == false)
            let covered = Set(claim.variants.flatMap(\.baselines))
            #expect(covered == Set(fixtures.keys))
            for variant in claim.variants {
                for baseline in variant.baselines {
                    #expect(fixtures[baseline]?.capabilities[claim.id] == variant.value)
                }
            }
            #expect(claim.variants.flatMap(\.baselines).count == fixtures.count)
        }

        let evidence = Set(manifest.claims.map(\.evidence))
            .union(manifest.protocols.supported.map(\.evidence))
            .union(manifest.limits.map(\.evidence))
        #expect(evidence.isSubset(of: Self.executableEvidence))
    }

    @Test("claimed terminfo key variants match DanTerm input encoding")
    func keyConformance() throws {
        let root = repositoryRoot()
        let manifest = try decode(
            CapabilityManifest.self,
            at: root.appending(path: "terminal-capabilities-v1.json")
        )
        let keys: [String: TerminalInputKey] = [
            "kcuu1": .up, "kcud1": .down, "kcub1": .left, "kcuf1": .right,
            "khome": .home, "kend": .end, "kdch1": .deleteForward,
            "kpp": .pageUp, "knp": .pageDown,
        ]

        for claim in manifest.claims where claim.kind == "key" {
            let key = try #require(keys[claim.id])
            let expected = try #require(claim.variants.first?.value)
            let modes = TerminalInputModes(applicationCursorKeys: true)
            #expect(String(decoding: encodeTerminalKey(
                key,
                modifiers: [],
                modes: modes
            ), as: UTF8.self) == expected)
        }
    }

    private static let executableEvidence: Set<String> = [
        "TerminalCapabilityManifestTests.keyConformance",
        "TerminalEditingTests",
        "TerminalHyperlinkTests",
        "TerminalInputStreamTests",
        "TerminalKeyEncodingTests",
        "TerminalMetadataIntegrationTests",
        "TerminalModeTests",
        "TerminalMouseEncodingTests",
        "TerminalOSC52Tests",
        "TerminalQueryTests",
        "TerminalScrollbackBudgetTests",
        "TerminalSemanticEventTests",
        "TerminalShellEventTests",
        "TerminalStyleTests",
    ]

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private struct CapabilityManifest: Decodable {
    let schemaVersion: Int
    let artifact: String
    let terminalIdentity: String
    let environment: [EnvironmentVariable]
    let baselines: [Baseline]
    let claims: [Claim]
    let protocols: ProtocolContract
    let limits: [Limit]
}

private struct EnvironmentVariable: Decodable {
    let name: String
    let value: String
    let ownership: String
    let visibility: String
}

private struct Baseline: Decodable {
    let id: String
    let fixture: String
    let provenance: String
}

private struct Claim: Decodable {
    let id: String
    let kind: String
    let evidence: String
    let variants: [Variant]
}

private struct Variant: Decodable {
    let value: String
    let baselines: [String]
}

private struct ProtocolContract: Decodable {
    let supported: [EvidenceItem]
    let denied: [String]
}

private struct EvidenceItem: Decodable {
    let id: String
    let evidence: String
}

private struct Limit: Decodable {
    let id: String
    let value: Int
    let unit: String
    let evidence: String
}

private struct TerminfoFixture: Decodable {
    let id: String
    let terminal: String
    let provenance: String
    let capabilities: [String: String]
}
