// Pure tests for detached rendering, coalesced publish retry, and idle quiescence.
import DanTermMobileKit
import Testing

@Test("Idle presentation schedules no work")
func idleSchedulesNothing() {
    let policy = MobilePresentationPolicy(surfaceIds: [0, 1])
    #expect(policy.nextAction == nil)
    #expect(policy.needsTick == false)
}

@Test("Damage renders only into a detached surface")
func attachedSurfaceIsNeverRenderTarget() {
    var policy = MobilePresentationPolicy(surfaceIds: [0, 1])
    policy.noteDamage()
    #expect(policy.nextAction == .render(surfaceId: 0))
    policy.didRender(surfaceId: 0)
    #expect(policy.nextAction == .publish(surfaceId: 0))
    policy.didPublish(surfaceId: 0)
    #expect(policy.attachedSurfaceId == 0)
    #expect(policy.needsTick == false)

    policy.noteDamage()
    #expect(policy.nextAction == .render(surfaceId: 1))
}

@Test("A coalesced publish retries on a later tick and then returns to idle")
func coalescedPublishRetries() {
    var policy = MobilePresentationPolicy(surfaceIds: ["a", "b"])
    policy.noteDamage()
    policy.didRender(surfaceId: "a")
    policy.didPublish(surfaceId: "a")
    policy.noteDamage()
    #expect(policy.nextAction == .render(surfaceId: "b"))
    policy.didRender(surfaceId: "b")
    policy.didCoalescePublish(surfaceId: "b")
    #expect(policy.attachedSurfaceId == "a")
    #expect(policy.nextAction == .retryPublish(surfaceId: "b"))
    #expect(policy.needsTick)
    policy.didPublish(surfaceId: "b")
    #expect(policy.attachedSurfaceId == "b")
    #expect(policy.nextAction == nil)
    #expect(policy.needsTick == false)
}
