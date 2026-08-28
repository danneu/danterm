// A minimal IPC runtime for server tests. It records every callback and completes
// served requests so tests can observe delivery without constructing AppRuntime.
import DanTermProtocol
import Foundation
import Synchronization
@testable import DanTerm

final class RecordingIpcRuntimeDispatch: Sendable {
    /// Keeps the caller stamp and decoded request together as the runtime received them.
    struct ServedRequest: Sendable {
        let caller: IpcCallerIdentity
        let request: IpcRequest
    }

    private struct State {
        var servedRequests: [ServedRequest] = []
        var closedConnectionIds: [UUID] = []
        var tailnetStatuses: [DanTermTailnetStatus] = []
    }

    private let state = Mutex(State())

    var servedRequests: [ServedRequest] {
        state.withLock { $0.servedRequests }
    }

    var closedConnectionIds: [UUID] {
        state.withLock { $0.closedConnectionIds }
    }

    var tailnetStatuses: [DanTermTailnetStatus] {
        state.withLock { $0.tailnetStatuses }
    }

    var dispatch: AppRuntimeIpcDispatch {
        AppRuntimeIpcDispatch(
            serve: { [self] connection, reqId, audit, caller, request in
                state.withLock {
                    $0.servedRequests.append(ServedRequest(caller: caller, request: request))
                }
                IpcRequestTransport(connection: connection, audit: audit).writeSuccess(
                    reqId: reqId,
                    result: JSONValue.object([:])
                )
            },
            connectionClosed: { [self] connectionId in
                state.withLock { $0.closedConnectionIds.append(connectionId) }
            },
            tailnetStatusChanged: { [self] status in
                state.withLock { $0.tailnetStatuses.append(status) }
            }
        )
    }
}
