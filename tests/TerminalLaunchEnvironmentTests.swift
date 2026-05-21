// Tests for the pure terminal launch environment helper.
import Foundation
import DanTermProtocol

func terminalLaunchEnvironmentTests() {
    print("Terminal launch environment tests:")

    test("terminal launch env includes pane context and omits tab context") {
        let paneId = PaneId()
        let env = terminalLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            token: "secret-token"
        )
        let dict = Dictionary(uniqueKeysWithValues: env)

        try expectEqual(dict[EnvVars.flag], "1")
        try expectEqual(dict[EnvVars.sock], "/tmp/danterm/control.sock")
        try expectEqual(dict[EnvVars.pane], paneId.rawValue.uuidString)
        try expectEqual(dict["DANTERM_TOKEN"], "secret-token")
        try expect(dict["DANTERM_TAB"] == nil, "new pane environments should not include DANTERM_TAB")
    }
}
