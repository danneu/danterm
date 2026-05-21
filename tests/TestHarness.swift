import Foundation

@main
struct TestRunner {
    static func main() {
        tabTests()
        paneTests()
        ghosttyTests()
        groupTests()
        lifecycleTests()
        alertTests()
        modelOperationsTests()
        snapshotTests()
        dragDropInputTests()
        paneToolbarTests()
        exportTests()
        dropZoneTests()
        customTitleTests()
        checkpointTests()
        searchTests()
        scrollbarMathTests()
        themeTests()
        remoteTests()
        themeColorParserTests()
        danTermConfigTests()
        preferencesTests()
        todoTests()
        updateTabTodoTests()
        todoShortcutCatalogTests()
        terminalLaunchEnvironmentTests()
        ipcUpdateTests()
        ipcConnectionTests()
        cliPathInstallerTests()
        todoPopoverStateTests()
        switcherEventTests()
        jumpEventTests()
        updateMruTests()
        updateJumpTests()
        print("\n\(total - failures)/\(total) passed")
        if failures > 0 { exit(1) }
    }
}

// MARK: - Test Harness

var failures = 0
var total = 0

struct TestFailure: Error {
    let message: String
}

func test(_ name: String, _ body: () throws -> Void) {
    total += 1
    do {
        try body()
        print("  \u{2713} \(name)")
    } catch let e as TestFailure {
        print("  \u{2717} \(name): \(e.message)")
        failures += 1
    } catch {
        print("  \u{2717} \(name): \(error)")
        failures += 1
    }
}

func expect(_ condition: Bool, _ message: String = "assertion failed", file: String = #file, line: Int = #line) throws {
    guard condition else { throw TestFailure(message: "\(message) (\(file):\(line))") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) throws {
    guard a == b else { throw TestFailure(message: "\(message.isEmpty ? "expected equal" : message): \(a) != \(b) (\(file):\(line))") }
}

// MARK: - Helpers

func makeModel() -> AppModel {
    let generalId = GroupId()
    return AppModel(
        groups: [GroupModel(id: generalId, name: "General")],
        panes: [:]
    )
}

/// Create a tab and return the effects (for inspection or ignoring).
@discardableResult
func createTab(_ model: inout AppModel, inGroupId: GroupId? = nil, background: Bool = false) -> [Effect] {
    return update(&model, .createTab(inGroupId: inGroupId, background: background))
}

func hasEffect(_ effects: [Effect], _ check: (Effect) -> Bool) -> Bool {
    effects.contains(where: check)
}
