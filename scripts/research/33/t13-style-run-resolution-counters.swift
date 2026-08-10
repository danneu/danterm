// Research doc 33, task T13: counters injected into an instrumented planner copy.

/// Counts semantic style segments and presentation-style resolutions for one frame.
struct T13Counters {
  var distinctStyleRuns = 0
  var resolveCellStyleCalls = 0
}

nonisolated(unsafe) var t13Counters = T13Counters()
