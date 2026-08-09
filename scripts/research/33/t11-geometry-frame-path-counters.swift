// Research doc 33, task T11: counters injected into an instrumented engine copy.

/// Counts geometry projection work reached by one frame plan.
struct T11Counters {
    var presentedRowGeometryCalls = 0
    var geometryRowAllocations = 0
}

nonisolated(unsafe) var t11Counters = T11Counters()
