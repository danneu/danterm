// Where bytes travelling toward a pane's child came from, in the one form the pane recorder
// can compare against the transfer stamp it takes when the write succeeds.
//
// Only the choice of stamp lives here. Threading it to the write boundary is the PTY host's
// job, and reading it back out is the tape's.
import AppKit
import Foundation

/// Stamps pane input with the moment it originated, on `DispatchTime`'s monotonic scale --
/// the same scale the pane recorder stamps completed transfers with, so the distance between
/// the two is time the app held the bytes.
///
/// The distinction the two cases draw is the whole point: an AppKit event was created by the
/// system before any app code ran, so a handler that sampled its own clock would charge every
/// delay ahead of it to the child. Input the app itself originates has no such earlier moment.
enum PaneInputOrigin {
    /// The occurrence time the system recorded when it created this event. `NSEvent.timestamp`
    /// is seconds on `mach_absolute_time`'s base, which is what `DispatchTime` counts in
    /// nanoseconds, so the two are directly comparable within a process.
    static func systemEvent(_ event: NSEvent) -> UInt64 {
        let nanoseconds = (event.timestamp * 1_000_000_000).rounded()
        guard nanoseconds > 0 else { return 0 }
        return UInt64(nanoseconds)
    }

    /// The moment input the app originated itself -- an IPC request, a menu action, a focus
    /// change -- entered the pane, taken before it is handed to the owner queue.
    static func appEntry() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
