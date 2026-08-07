// Research doc 33, task T6: the counter shim the instrumented DanTermCore copy increments.
//
// `t6-msg-work.py` copies `lib/DanTermCore/Sources/DanTermCore` and
// `lib/DanTermProtocol/Sources/DanTermProtocol` into a scratch directory, injects one call
// to a member of this type at each site this task counts, and compiles the result as one
// module with `t6-msg-work-probe.swift`. Nothing here is on a production path and the core
// in the repo is never edited.
//
// It holds counting only. Any decision about what the numbers mean belongs in the finding.

/// Tallies the work one `Msg` costs the pure half of the runtime: the `update()` call plus
/// the projection sweep `AppRuntime.reconcile()` runs after it.
///
/// The three families are kept apart because they answer different halves of `T23`'s claim.
/// The tree walks say how much of the model a pane-scoped message touches. The set and
/// shape constructions say how much of that work is re-derived from scratch every sweep.
/// The projection counters say how many whole-model passes a single named pane triggers.
struct T6Counters {
    // Tree walks. `panesInNodeCalls` is also the `[PaneModel]` allocation count, since every
    // node in the walk returns a fresh array; `panesInNodeLeaves` is the number of
    // `PaneModel` values copied out of leaves, each carrying its `todos` array.
    var allPanesWalks = 0
    var panesInNodeCalls = 0
    var panesInNodeLeaves = 0
    var paneLookups = 0
    var paneInNodeCalls = 0
    var allPaneIdsNodeCalls = 0
    var updatePaneCalls = 0
    var updatePaneInNodeCalls = 0

    // Set and shape construction rebuilt from scratch per sweep.
    var liveTabIdSets = 0
    var liveTabIdInserts = 0
    var containerShapeCalls = 0
    var containerShapeNodes = 0
    var alertTallies = 0
    var sumUnreadCalls = 0

    // Tab chrome. `TabModel.title`, `displayTitle` and `subtitle` are three computed
    // properties over one private `derivedChrome`, and nothing caches it -- so each read
    // costs one `paneInNode` walk plus `abbreviateHome`, whose default argument is an
    // `NSHomeDirectory()` call.
    var derivedChromeCalls = 0
    var abbreviateHomeCalls = 0

    // Projections. `projectionCalls` counts entries into the twelve pure projections the
    // sweep runs; `paneKeyedProjectionEntries` counts the per-pane dictionary entries the
    // three `allPanes`-keyed ones build, and `tabKeyedProjectionEntries` the per-tab rows
    // the sidebar and container-shape passes build.
    var projectionCalls = 0
    var paneKeyedProjectionEntries = 0
    var tabKeyedProjectionEntries = 0
}

nonisolated(unsafe) var t6Counters = T6Counters()
