#!/usr/bin/env bash
# Research doc 33, task T9 (vetting): establish by ablation which damage shape a
# one-line scroll publishes, above and below the history budget.
#
# Below the budget every scrolled line advances `scrollProjection.topRow`, so
# `recordDamage(from:to:)`'s topRow guard escalates to `.full`. At the budget
# the append and the eviction cancel in `topRow`, the guard never fires, and the
# scroll arrives as `moveAndFillRows`' row damage covering every viewport row
# instead -- the same whole-screen redraw through the other representation. The
# live sampler (t9-lines-per-delivery.sh) reads ~0.5 fullDamageShare on paced
# streams for exactly this reason: arena eviction is chunked, so `topRow`
# advances on some lines and holds on others.
#
# The probe runs as a scratch Swift Testing test materialized into the
# TerminalCore package (the `@testable` import is what reaches the internal
# budget-taking initializer), and is deleted afterwards.
#
# Usage: scripts/research/33/t9-damage-at-budget-probe.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROBE="$REPO_ROOT/lib/TerminalCore/Tests/TerminalCoreTests/ScratchT9DamageProbe.swift"

cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

cat > "$PROBE" <<'SWIFT'
// Scratch probe for research/33 T9 vetting; materialized and deleted by
// scripts/research/33/t9-damage-at-budget-probe.sh.
import Testing

@testable import TerminalCore

struct ScratchT9DamageProbe {
    @Test("per-line feed damage escalation census below the history budget")
    func perLineDamageCensus() throws {
        var terminal = try #require(Terminal(columns: 80, rows: 40))
        let line = "paced line 0123456789 abcdefghijklmnopqrstuvwxyz 0123456789"
        for _ in 0..<45 { terminal.feed(Array((line + "\r\n").utf8)) }
        _ = terminal.drainDamage()

        var full = 0
        var rowsOnly = 0
        var badDelta = 0
        var topBefore = terminal.absoluteViewportTopRow
        for _ in 0..<200 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            let topAfter = terminal.absoluteViewportTopRow
            if damage.isFull { full += 1 } else { rowsOnly += 1 }
            if topAfter - topBefore != 1 { badDelta += 1 }
            topBefore = topAfter
        }
        print("PROBE full: \(full), rowsOnly: \(rowsOnly), badDelta: \(badDelta)")
    }

    @Test("per-line feed damage census at the history budget")
    func perLineDamageCensusAtBudget() throws {
        var terminal = try #require(Terminal(
            columns: 80,
            rows: 40,
            scrollbackBudgetBytes: historyBudget(lines: 60, cells: 60, paneColumns: 80)
        ))
        let line = "paced line 0123456789 abcdefghijklmnopqrstuvwxyz 0123456789"
        for _ in 0..<300 { terminal.feed(Array((line + "\r\n").utf8)) }
        _ = terminal.drainDamage()

        var full = 0
        var rowsOnly = 0
        var rowsCounts = Set<Int>()
        var absoluteDeltaTotal = 0
        var topRowDeltaTotal = 0
        var absoluteBefore = terminal.absoluteViewportTopRow
        var topBefore = terminal.scrollProjection.topRow
        for _ in 0..<200 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            if damage.isFull { full += 1 } else {
                rowsOnly += 1
                rowsCounts.insert(damage.rows.count)
            }
            absoluteDeltaTotal += terminal.absoluteViewportTopRow - absoluteBefore
            topRowDeltaTotal += terminal.scrollProjection.topRow - topBefore
            absoluteBefore = terminal.absoluteViewportTopRow
            topBefore = terminal.scrollProjection.topRow
        }
        print("""
        PROBE-BUDGET full: \(full), rowsOnly: \(rowsOnly), rowsCounts: \(rowsCounts.sorted()), \
        absoluteDelta: \(absoluteDeltaTotal), topRowDelta: \(topRowDeltaTotal)
        """)
    }
}
SWIFT

swift test --package-path "$REPO_ROOT/lib/TerminalCore" \
    --filter ScratchT9DamageProbe 2>&1 | grep "PROBE"
