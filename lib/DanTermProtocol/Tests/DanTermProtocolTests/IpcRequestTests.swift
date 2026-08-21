// Behavioral coverage for the shared typed IPC request catalog.
import Foundation
import Testing
@testable import DanTermProtocol

struct IpcRequestTests {
    @Test("character keys require a modifier", arguments: ["a", "\\"])
    func characterKeysRequireModifier(_ key: String) throws {
        // Intent: plain characters have only the text spelling on the wire.
        // Why it exists: accepting an unmodified key spelling makes one keystroke
        //   ambiguous and forces every future mode to keep both forms equivalent.
        // Scenario: a direct client sends a letter or punctuation as a key with no mods.
        let pane = "11111111-1111-4111-8111-111111111111"
        let error = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.paneInput.rawValue,
                params: .object([
                    "pane": .string(pane),
                    "input": .array([.object(["key": .string(key)])]),
                ])
            )
        }
        #expect(error?.message == "character key requires at least one modifier")
    }

    @Test("modified character and wheel events round trip")
    func modifiedCharacterAndWheelEventsRoundTrip() throws {
        // Intent: the widened key and wheel cases preserve their intent through JSON.
        // Why it exists: a client and the app must agree on the stable event grammar.
        // Scenario: one request carries Ctrl-backslash and wheel-up at a viewport cell.
        let pane = PaneId(rawValue: UUID())
        let request = IpcRequest.paneInput(
            pane: pane,
            input: .events([
                .key(.character("\\"), [.ctrl]),
                .wheel(.up, column: 4, row: 2),
            ])
        )

        #expect(request.params["input"] == .array([
            .object([
                "key": .string("\\"),
                "mods": .array([.string("ctrl")]),
            ]),
            .object([
                "wheel": .string("up"),
                "column": .number(4),
                "row": .number(2),
            ]),
        ]))
        #expect(try IpcRequest.decode(
            method: request.method.rawValue,
            params: .object(request.params)
        ) == request)
    }

    // Intent: the wire decode resolves a tape request's mode and history budget into one
    //   policy, defaulting an absent budget and refusing the combinations that do not exist.
    // Why it exists: the budget is the only thing keeping a join off a multi-megabyte
    //   payload, so a request that stated a bad one must be refused at the door rather than
    //   silently rounded, dropped, or applied to a raw stream that sends no sync at all.
    // Scenario: spec-first contract for the bounded pane.tape request.
    @Test("pane.tape decodes its history budget and refuses budgets it cannot honor")
    func paneTapeDecodesHistoryBudget() throws {
        let pane = "11111111-1111-4111-8111-111111111111"
        func decode(_ extra: [String: JSONValue], mode: String = "reconstructible") throws -> IpcRequest {
            var params: [String: JSONValue] = [
                "pane": .string(pane),
                "start": .string("now"),
                "mode": .string(mode),
            ]
            params.merge(extra) { _, new in new }
            return try IpcRequest.decode(
                method: IpcRequestMethod.paneTape.rawValue,
                params: .object(params)
            )
        }

        let explicit = try decode(["syncHistoryBytes": .number(4096)])
        guard case .paneTape(_, _, _, let policy) = explicit else {
            Issue.record("expected a pane tape request")
            return
        }
        #expect(policy == .reconstructible(historyBudgetBytes: 4096))

        let defaulted = try decode([:])
        guard case .paneTape(_, _, _, let defaultPolicy) = defaulted else {
            Issue.record("expected a pane tape request")
            return
        }
        #expect(
            defaultPolicy
                == .reconstructible(
                    historyBudgetBytes: PaneTapeSyncPolicy.defaultHistoryBudgetBytes
                )
        )

        let rawStream = try decode([:], mode: "raw")
        guard case .paneTape(_, _, _, let rawPolicy) = rawStream else {
            Issue.record("expected a pane tape request")
            return
        }
        #expect(rawPolicy == .raw)

        for malformed: JSONValue in [.number(-1), .number(1.5), .string("4096"), .bool(true)] {
            let error = #expect(throws: IpcRequestDecodeError.self) {
                try decode(["syncHistoryBytes": malformed])
            }
            #expect(error?.message == "syncHistoryBytes must be a whole number of bytes, zero or more")
        }

        let inapplicable = #expect(throws: IpcRequestDecodeError.self) {
            try decode(["syncHistoryBytes": .number(4096)], mode: "raw")
        }
        #expect(
            inapplicable?.message
                == "syncHistoryBytes applies only to a reconstructible tape stream"
        )
    }

    @Test("every CLI request round trips through the shared catalog")
    func everyCLIRequestRoundTripsThroughCatalog() throws {
        // Intent: every command the CLI builds decodes to the same typed request.
        // Why it exists: separate CLI and daemon parameter transcriptions can drift
        //   while their independent tests remain green.
        // Scenario: one representative invocation for every client request method.
        let fixtures = try representativeCLICommands()

        #expect(Set(fixtures.map(\.command.method)) == Set(IpcRequestMethod.allCases.map(\.rawValue)))
        for fixture in fixtures {
            let command = fixture.command
            let decoded = try IpcRequest.decode(
                method: command.method,
                params: .object(command.params)
            )
            #expect(decoded == command.request)
        }
    }

    @Test("every audit target agrees with the request's wire params")
    func everyAuditTargetAgreesWithWireParams() throws {
        // Intent: every durable target key and id is the same entity sent on the wire.
        // Why it exists: the audit and wire projections were independent switches, so
        //   either could drift while its own focused tests stayed green.
        // Scenario: every representative request compares its audit target to params.
        for fixture in try representativeCLICommands() {
            for (key, value) in fixture.command.request.auditDescriptor.target {
                let wireValue = try #require(fixture.command.params[key]?.asString)
                #expect(value == wireValue.lowercased())
            }
        }
    }

    @Test("every audit descriptor admits only catalog-approved wire facts")
    func everyAuditDescriptorAdmitsOnlyApprovedWireFacts() throws {
        // Intent: every representative request admits targets, launch authority, and
        //   input quantity to its audit descriptor, and no other wire value.
        // Why it exists: independent request switches let group.new launch a command
        //   without recording it and could let another content field cross the boundary.
        // Scenario: one representative request for every catalog method, including
        //   launch-less tab creation and both pane input forms.
        var fixtures = try representativeCLICommands()
        let pane = PaneId(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        fixtures.append(RepresentativeCLICommand(CLICommand(
            request: .paneInput(pane: pane, input: .text("private input")),
            outputMode: .none
        )))

        for fixture in fixtures {
            let request = fixture.command.request
            let params = fixture.command.params
            let launch = params["launch"]?.asObject
            let admitsLaunch = [
                IpcRequestMethod.groupNew,
                .tabNew,
                .paneSplit,
            ].contains(request.method)
            let expectedInput: IpcAuditInputAccounting?
            switch request {
            case .paneInput(_, .text(let text)):
                expectedInput = .textBytes(text.utf8.count)
            case .paneInput(_, .events(let events)):
                expectedInput = .eventCount(events.count)
            default:
                expectedInput = nil
            }

            let descriptor = request.auditDescriptor
            #expect(descriptor.method == request.method.rawValue)
            #expect(descriptor.command == (admitsLaunch ? launch?["cmd"]?.asString : nil))
            #expect(descriptor.cwd == (admitsLaunch ? launch?["cwd"]?.asString : nil))
            #expect(descriptor.input == expectedInput)
        }
    }

    @Test("every targeting catalog fixture rejects its absent target")
    func everyTargetingCatalogMethodRejectsAbsentTarget() throws {
        // Intent: each distinct target form pins its own missing-target decode error.
        // Why it exists: test-only production metadata could omit a target and make
        //   the proof skip the request instead of catching the missing decision.
        // Scenario: each targeting fixture removes its declared target keys.
        for fixture in try representativeCLICommands() {
            #expect(
                fixture.command.request.auditDescriptor.target.isEmpty
                    == (fixture.missingTarget == nil)
            )
            guard let missingTarget = fixture.missingTarget else { continue }

            let command = fixture.command
            var params = command.params
            for key in missingTarget.keys { params.removeValue(forKey: key) }

            let error = #expect(throws: IpcRequestDecodeError.self) {
                try IpcRequest.decode(method: command.method, params: .object(params))
            }
            #expect(error?.message == missingTarget.message)
        }
    }

    @Test("quit is the only method that ends the instance it reaches")
    func quitIsTheOnlyInstanceEndingMethod() {
        // Intent: exactly one catalog method is classified as instance-ending.
        // Why it exists: the CLI derives two rules from that one fact -- refuse
        //   ambient targeting, and read a closed connection as success. A second
        //   method that silently inherited them would make every ordinary verb
        //   able to hide a dropped connection.
        let ending = IpcRequestMethod.allCases.filter(\.terminatesInstance)

        #expect(ending == [.quit])
    }

    @Test("quit is the only method that requires a local caller")
    func quitIsTheOnlyLocalCallerMethod() {
        // Intent: every catalog method makes an explicit remote-authority choice.
        // Why it exists: a new method must not silently inherit local or remote
        //   authority when it joins the exhaustive request catalog.
        // Scenario: the milestone-1 remote surface permits every method except quit.
        let localOnly = IpcRequestMethod.allCases.filter(\.requiresLocalCaller)

        #expect(localOnly == [.quit])
    }

    @Test("pane.resize decodes exactly one of the grid and fit forms")
    func paneResizeDecodesExactlyOneForm() throws {
        // Intent: the wire admits a grid or a fit, never both and never neither.
        // Why it exists: a request carrying a grid and a fit at once would leave
        //   the daemon to pick which half the caller meant, and picking is exactly
        //   what a last-writer-wins resize must never do.
        // Scenario: spec-first, covering both accepted forms and the mixed one.
        let pane = "11111111-1111-4111-8111-111111111111"
        let paneId = PaneId(rawValue: UUID(uuidString: pane)!)

        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["pane": .string(pane), "columns": .number(60), "rows": .number(20)])
        ) == .paneResize(pane: paneId, resize: .grid(columns: 60, rows: 20)))

        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["pane": .string(pane), "fit": .bool(true)])
        ) == .paneResize(pane: paneId, resize: .fit))

        let usage = "params must be columns and rows, or fit"
        for params: [String: JSONValue] in [
            ["pane": .string(pane)],
            ["pane": .string(pane), "columns": .number(60)],
            ["pane": .string(pane), "fit": .bool(true), "columns": .number(60), "rows": .number(20)],
            ["pane": .string(pane), "columns": .number(60.5), "rows": .number(20)],
            ["pane": .string(pane), "columns": .string("60"), "rows": .number(20)],
        ] {
            let error = #expect(throws: IpcRequestDecodeError.self) {
                try IpcRequest.decode(
                    method: IpcRequestMethod.paneResize.rawValue,
                    params: .object(params)
                )
            }
            #expect(error?.message == usage)
        }
    }

    @Test("pane.resize params round trip through the wire encoding")
    func paneResizeParamsRoundTrip() throws {
        // Intent: what a client encodes is what the daemon decodes back.
        // Why it exists: `params` and `decode` are written apart, so a spelling
        //   change on one side has to fail here rather than in a live session.
        // Scenario: spec-first, both forms of the same request.
        let paneId = PaneId(rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        for request: IpcRequest in [
            .paneResize(pane: paneId, resize: .grid(columns: 2, rows: 1)),
            .paneResize(pane: paneId, resize: .fit),
        ] {
            #expect(try IpcRequest.decode(
                method: request.method.rawValue,
                params: .object(request.params)
            ) == request)
        }
    }

    @Test("pane.split accepts exactly one well-formed target")
    func paneSplitAcceptsExactlyOneWellFormedTarget() throws {
        let pane = "11111111-1111-4111-8111-111111111111"
        let tab = "22222222-2222-4222-8222-222222222222"
        let paneId = PaneId(rawValue: UUID(uuidString: pane)!)
        let tabId = TabId(rawValue: UUID(uuidString: tab)!)

        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object(["pane": .string(pane), "direction": .string("horizontal")])
        ) == .paneSplit(target: .pane(paneId, direction: .horizontal), launch: nil, background: false))
        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object(["tab": .string(tab)])
        ) == .paneSplit(target: .tab(tabId), launch: nil, background: false))

        let malformed: [([String: JSONValue], String)] = [
            ([:], "pane or tab required"),
            (["pane": .string(pane), "tab": .string(tab), "direction": .string("horizontal")], "exactly one of pane or tab required"),
            (["pane": .string(pane)], "direction required with pane"),
            (["tab": .string(tab), "direction": .string("horizontal")], "direction is not valid with tab"),
        ]
        for (params, message) in malformed {
            let error = #expect(throws: IpcRequestDecodeError.self) {
                try IpcRequest.decode(method: IpcRequestMethod.paneSplit.rawValue, params: .object(params))
            }
            #expect(error?.message == message)
        }
    }

    @Test("todo requests accept either owner and reject ambiguous targeting")
    func todoRequestsRequireExactlyOneOwner() throws {
        let pane = "11111111-1111-4111-8111-111111111111"
        let tab = "22222222-2222-4222-8222-222222222222"

        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.todoList.rawValue,
            params: .object(["tab": .string(tab)])
        ) == .todoList(owner: .tab(TabId(rawValue: UUID(uuidString: tab)!))))

        let absent = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(method: IpcRequestMethod.todoList.rawValue, params: .object([:]))
        }
        #expect(absent?.message == "pane or tab required")

        let ambiguous = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.todoList.rawValue,
                params: .object(["pane": .string(pane), "tab": .string(tab)])
            )
        }
        #expect(ambiguous?.message == "exactly one of pane or tab required")
    }

    @Test("group.rename requires a string name", arguments: [
        JSONValue.null, .number(7), .object([:]),
    ])
    func groupRenameRequiresStringName(_ name: JSONValue) throws {
        // Intent: a `name` that is absent or not a string is rejected at decode.
        // Why it exists: `group.rename` has no clear-to-null form, so a null
        //   name must fail rather than decode to one.
        // Scenario: spec-first non-string names, plus the absent case below.
        let group = "33333333-3333-4333-8333-333333333333"

        let wrongType = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.groupRename.rawValue,
                params: .object(["group": .string(group), "name": name])
            )
        }
        #expect(wrongType?.message == "invalid name")

        let absent = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.groupRename.rawValue,
                params: .object(["group": .string(group)])
            )
        }
        #expect(absent?.message == "invalid name")
    }

    private struct MissingTargetExpectation {
        let keys: [String]
        let message: String
    }

    private struct RepresentativeCLICommand {
        let command: CLICommand
        let missingTarget: MissingTargetExpectation?

        init(
            _ command: CLICommand,
            removing keys: [String] = [],
            expects message: String? = nil
        ) {
            self.command = command
            missingTarget = message.map { MissingTargetExpectation(keys: keys, message: $0) }
        }
    }

    private func representativeCLICommands() throws -> [RepresentativeCLICommand] {
        let pane = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let tab = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let group = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let todo = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

        return [
            RepresentativeCLICommand(CLICommand(request: .doctorPermissions, outputMode: .none)),
            RepresentativeCLICommand(CLICommand(request: .ping, outputMode: .none)),
            // Built by the phone client rather than by a CLI verb, like the two above.
            // It still belongs here: the catalog proof is what stops a method from
            // joining the enum without a decode that round trips.
            RepresentativeCLICommand(CLICommand(request: .roster, outputMode: .none)),
            RepresentativeCLICommand(try parseCLI(["ls"])),
            RepresentativeCLICommand(try parseCLI(["focus"])),
            RepresentativeCLICommand(try parseCLI(["tailnet", "status"])),
            RepresentativeCLICommand(try parseCLI(["quit"])),
            RepresentativeCLICommand(
                try parseCLI(["tab", "new", "--group", group], currentDirectory: "/caller"),
                removing: ["group"], expects: "group required"
            ),
            RepresentativeCLICommand(
                CLICommand(
                    request: .tabNew(
                        target: .afterTab(TabId(rawValue: UUID(uuidString: tab)!)),
                        launch: nil,
                        background: false
                    ),
                    outputMode: .none
                ),
                removing: ["afterTabId"], expects: "position=afterTab requires afterTabId"
            ),
            RepresentativeCLICommand(try parseCLI(["tab", "rename", "--tab", tab, "work"]), removing: ["tab"], expects: "tab required"),
            RepresentativeCLICommand(try parseCLI(["tab", "close", "--tab", tab]), removing: ["tab"], expects: "tab required"),
            RepresentativeCLICommand(try parseCLI(["group", "new", "--name", "notes"], currentDirectory: "/caller")),
            RepresentativeCLICommand(try parseCLI(["group", "rename", "--group", group, "notes"]), removing: ["group"], expects: "group required"),
            RepresentativeCLICommand(try parseCLI(["group", "close", "--group", group]), removing: ["group"], expects: "group required"),
            RepresentativeCLICommand(try parseCLI(["pane", "focus", "--pane", pane]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "info", "--pane", pane]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "split", "--pane", pane, "-h"]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["pane", "close", "--pane", pane]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "input", "--pane", pane, "--", "C-c"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "read", "--pane", pane, "--lines", "20"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "rows", "--pane", pane]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "zoom", "--pane", pane, "on"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "resize", "--pane", pane, "60x20"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "tape", "--pane", pane, "--follow"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["pane", "snapshot", "--pane", pane]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["theme", "set", "--pane", pane, "Tokyo Night"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["agent", "attach", "--pane", pane, "--kind", "codex", "--id", "thread-1"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["agent", "activity", "--pane", pane, "--kind", "codex", "--id", "thread-1", "--state", "working"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["agent", "detach", "--pane", pane, "--kind", "codex", "--id", "thread-1"]), removing: ["pane"], expects: "pane required"),
            RepresentativeCLICommand(try parseCLI(["todo", "list", "--pane", pane]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "add", "--pane", pane, "write", "test"]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "edit", "--pane", pane, todo, "write", "test"]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "done", "--pane", pane, todo]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "open", "--pane", pane, todo]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "delete", "--pane", pane, todo]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "clear-completed", "--pane", pane]), removing: ["pane"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "list", "--tab", tab]), removing: ["tab"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "add", "--tab", tab, "write", "test"]), removing: ["tab"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "edit", "--tab", tab, todo, "write", "test"]), removing: ["tab"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "done", "--tab", tab, todo]), removing: ["tab"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "open", "--tab", tab, todo]), removing: ["tab"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "delete", "--tab", tab, todo]), removing: ["tab"], expects: "pane or tab required"),
            RepresentativeCLICommand(try parseCLI(["todo", "clear-completed", "--tab", tab]), removing: ["tab"], expects: "pane or tab required"),
        ]
    }
}
