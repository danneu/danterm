// Pins the channel a reconcile pass reports through instead of sending: the
// ordering rule ReconcileFollowUps enforces, and the premise that makes the
// channel necessary -- update()'s own rename-target chokepoint covers only a
// target that left the model.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct ReconcileFollowUpTests {
    @Test("a follow-up is dispatched only after the outermost send frame returns")
    func outermostFrameOnlyDispatches() {
        // Intent: what a sweep's passes reported stays queued for as long as any
        //   send frame is open, and is released once the outermost one closes.
        // Why it exists: a follow-up dispatched mid-sweep re-enters a pass whose
        //   projection cache the outer sweep has not advanced yet.
        // Scenario: an outer send whose sweep provokes a nested send; both
        //   frames report, and nothing may leave until the outer frame returns.
        var followUps = ReconcileFollowUps()

        followUps.enterFrame()
        followUps.report([.sidebarRenameEnded])
        #expect(followUps.nextToDispatch() == nil,
            "the frame that reported must not dispatch its own follow-up")

        followUps.enterFrame()   // a send arriving mid-sweep
        followUps.report([.paneBecameFirstResponder(paneId: PaneId())])
        #expect(followUps.nextToDispatch() == nil,
            "a nested frame never drains")
        followUps.leaveFrame()
        #expect(followUps.nextToDispatch() == nil,
            "the outer frame is still open")

        followUps.leaveFrame()
        guard case .sidebarRenameEnded = followUps.nextToDispatch() else {
            Issue.record("the outermost frame dispatches in report order")
            return
        }
        guard case .paneBecameFirstResponder = followUps.nextToDispatch() else {
            Issue.record("the nested frame's follow-up rides the outermost drain")
            return
        }
        #expect(followUps.nextToDispatch() == nil)
        #expect(followUps.isEmpty)
    }

    @Test("draining keeps yielding what a follow-up's own sweep reports")
    func drainingContinuesAfterAFollowUpReports() {
        // Intent: the drain loop is not a single pass over a snapshot -- a
        //   follow-up whose own sweep reports another fact still gets drained.
        // Why it exists: the channel would silently strand the second fact for a
        //   whole turn, which is the deferral this design removes.
        // Scenario: dispatching the first follow-up opens a frame that reports a
        //   second one.
        var followUps = ReconcileFollowUps()
        followUps.enterFrame()
        followUps.report([.sidebarRenameEnded])
        followUps.leaveFrame()

        var dispatched: [Msg] = []
        var reportedOnce = false
        while let next = followUps.nextToDispatch() {
            dispatched.append(next)
            followUps.enterFrame()
            if !reportedOnce {
                reportedOnce = true
                followUps.report([.sidebarRenameEnded])
            }
            followUps.leaveFrame()
        }

        #expect(dispatched.count == 2,
            "the loop drained the fact the first follow-up's sweep reported")
    }

    @Test("update's rename-target chokepoint covers only a target that left the model")
    func chokepointClearsOnlyAbsentTargets() throws {
        // Intent: update() clears sidebarRenameTarget when the edited entity is
        //   gone, and leaves it alone when the entity is still there.
        // Why it exists: the load-bearing premise for the reported-message
        //   channel. If the chokepoint covered every mid-pass cause, the view
        //   would have nothing to report and the channel could be deleted.
        // Scenario: a live group rename survives an unrelated model change (the
        //   shape a wholesale rebuild or a selection move takes), and is cleared
        //   only once its own group is deleted.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroupInteractively(name: "New group"))
        let renamed = try #require(model.groups.last).id
        #expect(model.sidebarRenameTarget == .group(renamed))

        _ = update(&model, .createGroup(name: "Another group"))
        #expect(model.sidebarRenameTarget == .group(renamed),
            "a model change that keeps the edited group must not clear the target")

        _ = update(&model, .deleteGroup(id: renamed, moveTabs: false))
        #expect(model.sidebarRenameTarget == nil,
            "removing the edited group is the one cause the chokepoint covers")
    }
}
