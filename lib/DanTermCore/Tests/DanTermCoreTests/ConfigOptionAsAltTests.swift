// Pins Option-as-Alt as model-owned configuration and the pure side-routing policy.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

struct ConfigOptionAsAltTests {
    @Test("Preferences projects and edits all Option-as-Alt choices", arguments: [
        nil,
        OptionAsAlt.left,
        OptionAsAlt.right,
        OptionAsAlt.both,
    ])
    func preferencesProjectsAndEditsOptionAsAlt(_ choice: OptionAsAlt?) throws {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())

        _ = update(&model, .prefSet(.optionAsAlt(choice)))

        #expect(model.preferencesDraft?.config.optionAsAlt == choice)
        #expect(try #require(desiredPreferencesPanel(in: model)).optionAsAlt == choice)
    }

    @Test("saving Option-as-Alt changes every pane config key")
    func savingOptionAsAltChangesEveryPaneConfigKey() throws {
        var model = makeModel()
        _ = createTab(&model)
        let firstPane = try #require(model.groups.first?.tabs.first?.paneTree.focusedPaneId)
        _ = update(&model, .splitPane(paneId: firstPane, direction: .horizontal))
        let before = desiredPaneConfig(in: model)
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.optionAsAlt(.right)))

        let commands = update(&model, .prefSave)
        let after = desiredPaneConfig(in: model)

        #expect(after.count == 2)
        #expect(after.values.allSatisfy { $0.optionAsAlt == .right })
        #expect(after.keys.allSatisfy { after[$0] != before[$0] })
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.optionAsAlt == .right }
            return false
        })
    }

    @Test("selected Option sides route to terminal Alt", arguments: [
        (OptionAsAlt.left, OptionKeySides.left, true),
        (OptionAsAlt.left, OptionKeySides.right, false),
        (OptionAsAlt.right, OptionKeySides.left, false),
        (OptionAsAlt.right, OptionKeySides.right, true),
        (OptionAsAlt.both, OptionKeySides.left, true),
        (OptionAsAlt.both, OptionKeySides.right, true),
        (OptionAsAlt.left, OptionKeySides.left.union(.right), true),
        (OptionAsAlt.right, OptionKeySides.left.union(.right), true),
    ])
    func selectedOptionSidesRouteToTerminalAlt(
        _ policy: OptionAsAlt,
        _ sides: OptionKeySides,
        _ expected: Bool
    ) {
        #expect(optionRoutesToTerminalAlt(policy: policy, heldSides: sides) == expected)
    }

    @Test("an unsided Option event follows the left-side policy", arguments: [
        (nil, false),
        (OptionAsAlt.left, true),
        (OptionAsAlt.right, false),
        (OptionAsAlt.both, true),
    ])
    func unsidedOptionFollowsLeftPolicy(_ policy: OptionAsAlt?, _ expected: Bool) {
        #expect(optionRoutesToTerminalAlt(policy: policy, heldSides: []) == expected)
    }
}
