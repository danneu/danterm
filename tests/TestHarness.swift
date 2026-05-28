import Foundation

@main
struct TestRunner {
    static func main() {
        ipcUpdateTests()
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
        groups: [GroupModel(id: generalId, name: "General")]
    )
}

/// Create a tab and return the commands (for inspection or ignoring).
@discardableResult
func createTab(_ model: inout AppModel, inGroupId: GroupId? = nil, background: Bool = false) -> [Command] {
    return update(&model, .createTab(inGroupId: inGroupId, background: background))
}

func hasEffect(_ commands: [Command], _ check: (Command) -> Bool) -> Bool {
    commands.contains(where: check)
}

// MARK: - Snapshot (v2 leaf-embedded) test helpers

/// Collect every leaf's embedded PaneSnapshot from a snapshot split tree.
func paneSnapshots(in node: SplitNodeSnapshot) -> [PaneSnapshot] {
    switch node {
    case .leaf(let ps): return [ps]
    case .split(_, _, let first, let second, _):
        return paneSnapshots(in: first) + paneSnapshots(in: second)
    }
}

/// Every PaneSnapshot embedded across all of a snapshot's tab trees.
func allPaneSnapshots(_ snapshot: AppModelSnapshot) -> [PaneSnapshot] {
    snapshot.groups.flatMap(\.tabs).flatMap { paneSnapshots(in: $0.rootNode) }
}

/// Find an embedded PaneSnapshot by its id string.
func paneSnapshot(_ id: String, in snapshot: AppModelSnapshot) -> PaneSnapshot? {
    allPaneSnapshots(snapshot).first { $0.id == id }
}

