// Pins where a pane's input says it came from: the system event's own occurrence time, on the
// clock the pane recorder stamps completed transfers with.
import AppKit
import Foundation
import Testing
@testable import DanTerm

struct PaneInputOriginTests {
    @Test("a system event's origin is when the event occurred, not when the handler ran")
    func systemEventOriginIsTheEventsOwnTime() throws {
        // Intent: the origin an AppKit handler reports for a key event is the event's own
        // occurrence time, so the distance to the transfer stamp covers the app's own delay.
        // Why it exists: a handler that sampled the clock instead would charge every stall
        // before it ran to the child, which is exactly the ambiguity the tape exists to remove.
        // Scenario: an event that occurred 250ms ago reaches its handler only now.
        let occurred = DispatchTime.now().uptimeNanoseconds - 250_000_000
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: Double(occurred) / 1_000_000_000,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        let origin = PaneInputOrigin.systemEvent(event)
        let handlerClock = PaneInputOrigin.appEntry()

        #expect(origin < handlerClock)
        #expect(handlerClock - origin >= 200_000_000)
        #expect(handlerClock - origin <= 400_000_000)
    }

    @Test("an app-originated submission is stamped on the recorder's clock")
    func appEntryOriginSharesTheRecorderClock() {
        // Intent: input the app itself originates -- an IPC request, a menu paste -- is stamped
        // on the same monotonic scale the pane recorder stamps transfers with.
        // Why it exists: a stamp taken from another clock would produce a meaningless distance
        // between origin and transfer, or a negative one.
        // Scenario: two clock reads bracket one app-entry stamp.
        let before = DispatchTime.now().uptimeNanoseconds
        let origin = PaneInputOrigin.appEntry()
        let after = DispatchTime.now().uptimeNanoseconds

        #expect(origin >= before)
        #expect(origin <= after)
    }
}
