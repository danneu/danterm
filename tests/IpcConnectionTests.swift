// Tests for DanTerm IPC line framing, independent of real sockets.
import Foundation
import DanTermProtocol

func ipcConnectionTests() {
    print("IPC connection tests:")

    test("one full line emits one frame") {
        var framer = IpcLineFramer()
        let events = framer.append(ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#))
        try expectEqual(events.count, 1)
        guard case .line(let line) = events[0] else {
            throw TestFailure(message: "expected line event")
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        try expectEqual(request.method, Methods.ls)
    }

    test("two full lines in one read emit two frames") {
        var framer = IpcLineFramer()
        var chunk = ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#)
        chunk.append(ipcLine(#"{"jsonrpc":"2.0","id":2,"method":"tab.title"}"#))
        let events = framer.append(chunk)
        try expectEqual(events.count, 2)
    }

    test("split frame reassembles after second chunk") {
        var framer = IpcLineFramer()
        try expectEqual(framer.append(Data(#"{"jsonrpc":"#.utf8)).count, 0)
        let events = framer.append(ipcLine(#""2.0","id":1,"method":"ls"}"#))
        try expectEqual(events.count, 1)
        guard case .line(let line) = events[0] else {
            throw TestFailure(message: "expected line event")
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        try expectEqual(request.method, Methods.ls)
    }

    test("oversized line emits rejection event") {
        var framer = IpcLineFramer()
        let data = Data(repeating: 65, count: IpcLineFramer.maxLineBytes + 1)
        let events = framer.append(data)
        try expect(events.contains(.oversized), "expected oversized event")
    }
}

private func ipcLine(_ string: String) -> Data {
    var data = Data(string.utf8)
    data.append(0x0A)
    return data
}
