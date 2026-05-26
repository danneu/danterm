// Tests for the view reconciler's pure primitives (Stage 3+): the generic
// `applyDiff` diff/apply/prune helper. Reconcile *passes* themselves touch
// AppKit and are manual-QA-only; this file covers the structure-insensitive
// pure plumbing the passes are built on.
import Foundation

func reconcileTests() {
    print("Reconcile Tests...")

    // MARK: - applyDiff

    test("applyDiff applies only changed/new keys and skips unchanged ones") {
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        let desired: [String: Int] = ["a": 1, "b": 99, "c": 3]
        applyDiff(desired, &cache, apply: { k, _ in applied.append(k) })

        try expectEqual(Set(applied), Set(["b", "c"]),
            "only the changed key (b) and new key (c) apply")
        try expect(!applied.contains("a"), "unchanged key (a) is skipped")
        try expectEqual(cache, desired, "cache matches desired after the diff")
    }

    test("applyDiff invokes remove exactly once for a disappeared key, then prunes it") {
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        var removed: [String] = []
        let desired: [String: Int] = ["a": 1]  // 'b' left the desired set
        applyDiff(desired, &cache,
            apply: { k, _ in applied.append(k) },
            remove: { k in removed.append(k) })

        try expect(applied.isEmpty, "no key changed, so nothing applies")
        try expectEqual(removed, ["b"], "the disappeared key invokes remove exactly once")
        try expectEqual(cache, ["a": 1], "the disappeared key is pruned from the cache")
    }

    test("applyDiff with the default no-op remove still prunes disappeared keys") {
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        let desired: [String: Int] = ["a": 1]
        applyDiff(desired, &cache, apply: { k, _ in applied.append(k) })

        try expect(applied.isEmpty, "no changes apply")
        try expectEqual(cache, ["a": 1],
            "the disappeared key is pruned even when remove is the default no-op")
    }

    // MARK: - Effect.isPostReconcile (command-phase split, Stage 4)

    test("Effect.isPostReconcile: only focusSearchField defers past reconcile") {
        let pane = PaneId()
        // focusSearchField targets the search field reconcilePaneChrome creates, so
        // it must run after reconcile().
        try expect(Effect.focusSearchField(paneId: pane).isPostReconcile,
            "focusSearchField is post-reconcile")
        // makeFirstResponder stays pre-reconcile in Stage 4: its TerminalView is
        // still built by the effect-built container path (flips in Stage 8).
        try expect(!Effect.makeFirstResponder(paneId: pane).isPostReconcile,
            "makeFirstResponder stays pre-reconcile")
        // focusSurface acts on an already-existing surface; deferring it is wrong.
        try expect(!Effect.focusSurface(paneId: pane, focused: true).isPostReconcile,
            "focusSurface is pre-reconcile")
        // A representative sample of other commands are pre-reconcile.
        try expect(!Effect.createSurface(paneId: pane, cwd: nil, command: nil).isPostReconcile,
            "createSurface is pre-reconcile")
        try expect(!Effect.applyPaneTheme(paneId: pane).isPostReconcile,
            "applyPaneTheme is pre-reconcile")
        try expect(!Effect.sendEndSearch(paneId: pane).isPostReconcile,
            "sendEndSearch is pre-reconcile")
        try expect(!Effect.scheduleCheckpoint.isPostReconcile,
            "scheduleCheckpoint is pre-reconcile")
        try expect(!Effect.terminate.isPostReconcile,
            "terminate is pre-reconcile")
    }
}
