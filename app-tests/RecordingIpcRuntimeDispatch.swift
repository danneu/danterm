// A minimal IPC runtime for server tests. It records every callback and completes
// served requests so tests can observe delivery without constructing AppRuntime.
import DanTermProtocol
import Foundation
import Synchronization
@testable import DanTerm

final class RecordingIpcRuntimeDispatch: Sendable {
    private struct State {
        var messages: [IpcServerRuntimeMessage] = []
        var closedConnectionIds: [UUID] = []
        var tailnetStatuses: [DanTermTailnetStatus] = []
    }

    private let state = Mutex(State())

    var messages: [IpcServerRuntimeMessage] {
        state.withLock { $0.messages }
    }

    var closedConnectionIds: [UUID] {
        state.withLock { $0.closedConnectionIds }
    }

    var tailnetStatuses: [DanTermTailnetStatus] {
        state.withLock { $0.tailnetStatuses }
    }

    var dispatch: AppRuntimeIpcDispatch {
        AppRuntimeIpcDispatch(
            serve: { [self] connection, reqId, audit, message in
                state.withLock { $0.messages.append(message) }
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
