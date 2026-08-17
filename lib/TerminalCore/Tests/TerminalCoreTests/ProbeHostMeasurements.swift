// Host-process readings the env-gated probes take beside their own numbers: physical footprint,
// allocator pressure relief, and system load.
//
// They live in their own file because they are the only part of the probe island that outlives any
// one probe. They read the process, not the terminal, so they touch no `TerminalCore` API at all,
// which is what lets a probe paired against an older revision be copied into a checkout of it and
// still build: carry this file along when that revision does not already define these three, and
// leave it behind when it does.
//
// Belongs here: a reading of the host process that more than one probe needs. Does not belong here:
// anything that touches a terminal, a stimulus, a statistic over samples, or a threshold. Those
// belong to the probe that owns the question.
import Darwin
import Foundation

/// The process's physical footprint, the same `task_vm_info.phys_footprint` quantity
/// `TerminalMemoryProbeSupport#processPhysicalFootprintBytes` reads.
///
/// Deliberately duplicated rather than imported. `Terminal.LogicalLineStore` is internal to
/// `TerminalCore`, so a probe binary linked against the public library cannot see the arena at all
/// and the reading has to run where `@testable import` reaches it. Importing
/// `TerminalMemoryProbeSupport` would also break the baseline-copy property this file exists for:
/// that library is not a product at the revisions the probes are paired against.
func residentFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Asks every malloc zone to hand back the free pages it is sitting on, so a footprint sample
/// describes what is *retained* rather than what has merely been touched.
///
/// Asked on both sides of a residency window, because building a stimulus allocates and frees tens
/// of megabytes and an opening sample taken over those pages describes the build.
///
/// The request is best effort, and on macOS 26 it is inert: measured on Darwin 25.5, the one zone
/// present returned zero released bytes and `phys_footprint` did not move a page after hundreds of
/// megabytes of churn. `TerminalMemoryProbeSupport#settleAllocator` is the twin of this function and
/// records that measurement in full; it returns the released bytes so its report can publish them,
/// while a probe that only brackets a delta has nothing to do with the number. So no probe may
/// credit this call with an effect on its readings -- ask, and report what the footprint says.
func settleAllocator() {
    malloc_zone_pressure_relief(nil, 0)
}

/// The one-minute load average, or an explicit "unavailable" -- never a 0 that reads as calm.
func loadAverageDescription() -> String {
    var averages = [Double](repeating: 0, count: 3)
    guard getloadavg(&averages, 3) == 3 else { return "unavailable" }
    return String(format: "%.2f", averages[0])
}
