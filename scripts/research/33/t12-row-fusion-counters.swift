// Research doc 33, task T12: counters injected into an instrumented planner copy.

/// Counts transient cell-row allocations and full cell passes made by one frame plan.
struct T12Counters {
    var plannedCellRowAllocations = 0
    var cellRowPasses = 0
}

nonisolated(unsafe) var t12Counters = T12Counters()
