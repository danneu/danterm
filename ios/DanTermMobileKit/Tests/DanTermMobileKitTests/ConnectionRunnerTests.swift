// Verifies that background cancellation is a delivery fence, even after a frame is read.
import Foundation
import Testing
import DanTermClient
import DanTermProtocol
@testable import DanTermMobileKit

/// Returns one frame immediately, then blocks until cancellation closes the transport.
private final class ImmediateFrameTransport: DanTermClientTransport, @unchecked Sendable {
    static let livenessPolicy = DanTermClientLivenessPolicy.exempt

    private let condition = NSCondition()
    private var frame: Data?
    private var closed = false
    private var waitingAfterFrame = false

    init(frame: JsonRpcRequest) throws {
        self.frame = try encodeIpcLine(frame)
    }

    func send(_ bytes: Data) throws {}

    func receive() throws -> Data {
        condition.lock()
        if let frame {
            self.frame = nil
            condition.unlock()
            return frame
        }
        waitingAfterFrame = true
        condition.broadcast()
        while closed == false { condition.wait() }
        condition.unlock()
        return Data()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilFrameWasReturned() {
        condition.lock()
        while waitingAfterFrame == false { condition.wait() }
        condition.unlock()
    }
}

/// Collects runner output under a lock so the reader thread can be checked safely.
private final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MobileConnectionRunnerEvent] = []

    func append(_ value: MobileConnectionRunnerEvent) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [MobileConnectionRunnerEvent] {
        lock.withLock { values }
    }
}

/// Lets the test wait for the synchronous reader thread without a timing delay.
private final class ThreadCompletion: @unchecked Sendable {
    private let condition = NSCondition()
    private var finished = false

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while finished == false { condition.wait() }
        condition.unlock()
    }
}

/// Holds a serial queue so the test can leave a delivered frame pending behind it.
private final class QueueGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func block() {
        condition.lock()
        entered = true
        condition.broadcast()
        while released == false { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() {
        condition.lock()
        while entered == false { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Holds one active callback and records whether it finished before cancellation returned.
private final class DeliveryFenceProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var deliveryEntered = false
    private var releaseDelivery = false
    private var order: [String] = []

    func deliver(_ event: MobileConnectionRunnerEvent) {
        guard case .frame = event else { return }
        condition.lock()
        deliveryEntered = true
        condition.broadcast()
        while releaseDelivery == false { condition.wait() }
        order.append("delivery")
        condition.unlock()
    }

    func waitForDelivery() {
        condition.lock()
        while deliveryEntered == false { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        releaseDelivery = true
        condition.broadcast()
        condition.unlock()
    }

    func recordCancellation() {
        condition.lock()
        order.append("cancel")
        condition.unlock()
    }

    var recordedOrder: [String] {
        condition.withLock { order }
    }
}

struct ConnectionRunnerTests {
    @Test("cancellation drops a queued frame and fences every later delivery")
    func cancellationFencesDelivery() throws {
        // Intent: background cancellation returns only after shell output is impossible.
        // Why it exists: a reader can already own a frame when the app backgrounds.
        // Scenario: a frame waits on the shell queue while cancellation closes the session.
        let transport = try ImmediateFrameTransport(frame: JsonRpcRequest(method: "ready"))
        let session = DanTermClientSession(transport: transport)
        let deliveries = DeliveryLog()
        let deliveryQueue = DispatchQueue(label: "connection-runner-pending-delivery")
        let queueGate = QueueGate()
        deliveryQueue.async { queueGate.block() }
        queueGate.waitUntilEntered()
        let runner = MobileConnectionRunner(
            session: session,
            deliveryQueue: deliveryQueue
        ) { deliveries.append($0) }
        let completion = ThreadCompletion()
        let reader = Thread {
            runner.run()
            completion.finish()
        }

        reader.start()
        transport.waitUntilFrameWasReturned()
        runner.cancel()
        completion.wait()
        queueGate.release()
        deliveryQueue.sync {}

        #expect(deliveries.snapshot.isEmpty)
    }

    @Test("cancellation waits for a shell callback that already owns a frame")
    func cancellationWaitsForActiveDelivery() throws {
        // Intent: cancellation is a join point for a callback already in progress.
        // Why it exists: returning early could let stale state reach a backgrounded shell.
        // Scenario: the callback holds a received frame while another thread cancels.
        let transport = try ImmediateFrameTransport(frame: JsonRpcRequest(method: "ready"))
        let session = DanTermClientSession(transport: transport)
        let probe = DeliveryFenceProbe()
        let runner = MobileConnectionRunner(
            session: session,
            deliveryQueue: DispatchQueue(label: "connection-runner-active-delivery")
        ) { probe.deliver($0) }
        let readerFinished = ThreadCompletion()
        Thread {
            runner.run()
            readerFinished.finish()
        }.start()

        probe.waitForDelivery()
        let cancelStarted = ThreadCompletion()
        let cancelFinished = ThreadCompletion()
        Thread {
            cancelStarted.finish()
            runner.cancel()
            probe.recordCancellation()
            cancelFinished.finish()
        }.start()
        cancelStarted.wait()
        probe.release()
        cancelFinished.wait()
        readerFinished.wait()

        #expect(probe.recordedOrder == ["delivery", "cancel"])
    }
}
