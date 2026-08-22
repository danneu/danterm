// Pure Settings transactions for editing and validating the effective keybinding map.
import DanTermProtocol

/// Applies one keybinding editor transition and commits accepted edits immediately.
func updateKeybindingPreferences(
    _ model: inout AppModel,
    edit: KeybindingPreferenceEdit
) -> [Command] {
    guard model.preferencesDraft != nil else { return [] }

    switch edit {
    case .beginRecording(let id):
        guard commandCatalog.contains(where: { $0.id == id }) else { return [] }
        model.preferencesDraft!.recordingKeybindingFor = id
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = nil
        return []

    case .cancelRecording:
        model.preferencesDraft!.recordingKeybindingFor = nil
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = nil
        return []

    case .rejectRecording(let diagnostic):
        model.preferencesDraft!.recordingKeybindingFor = nil
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = diagnostic
        return []

    case .cancelConflictMove:
        model.preferencesDraft!.keybindingConflict = nil
        return []

    case .confirmConflictMove:
        guard let conflict = model.preferencesDraft!.keybindingConflict,
              let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value
        else { return [] }
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[conflict.source] = bindings[conflict.source, default: []]
            .filter { $0 != conflict.chord }
        var destination = bindings[conflict.destination, default: []]
        if destination.contains(conflict.chord) == false {
            destination.append(conflict.chord)
        }
        overrides.chordsByAction[conflict.destination] = destination
        return validateAndCommit(&model, overrides)

    case .add(let chord, let id):
        guard let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              let current = bindings[id]
        else { return [] }
        if current.contains(chord) {
            model.preferencesDraft!.recordingKeybindingFor = nil
            return []
        }
        if let owner = bindings.first(where: { $0.key != id && $0.value.contains(chord) })?.key {
            model.preferencesDraft!.recordingKeybindingFor = nil
            model.preferencesDraft!.keybindingDiagnostic = nil
            model.preferencesDraft!.keybindingConflict = KeybindingConflict(
                chord: chord,
                source: owner,
                destination: id
            )
            return []
        }
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = current + [chord]
        return validateAndCommit(&model, overrides)

    case .replace(let chords, let id):
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = chords
        return validateAndCommit(&model, overrides)

    case .remove(let index, let id):
        guard let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              var chords = bindings[id], chords.indices.contains(index)
        else { return [] }
        chords.remove(at: index)
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = chords
        return validateAndCommit(&model, overrides)

    case .makePrimary(let index, let id):
        guard let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              var chords = bindings[id], chords.indices.contains(index)
        else { return [] }
        let chord = chords.remove(at: index)
        chords.insert(chord, at: 0)
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = chords
        return validateAndCommit(&model, overrides)

    case .disable(let id):
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = []
        return validateAndCommit(&model, overrides)

    case .reset(let id):
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = nil
        return validateAndCommit(&model, overrides)

    case .resetAll:
        let known = Set(commandCatalog.map(\.id))
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction = overrides.chordsByAction.filter { known.contains($0.key) == false }
        return validateAndCommit(&model, overrides)
    }
}

/// Rejects an invalid candidate without changing either committed or draft config.
private func validateAndCommit(
    _ model: inout AppModel,
    _ overrides: KeybindingOverrides
) -> [Command] {
    let result = effectiveBindings(overrides: overrides)
    guard result.value != nil else {
        model.preferencesDraft!.recordingKeybindingFor = nil
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = result.diagnostics.first
        return []
    }
    return commitKeybindingOverrides(&model, overrides)
}

/// Installs one validated map in both owners before emitting its single disk write.
private func commitKeybindingOverrides(
    _ model: inout AppModel,
    _ overrides: KeybindingOverrides
) -> [Command] {
    let changed = overrides != model.config.keybindingOverrides
    model.config.keybindingOverrides = overrides
    model.preferencesDraft!.config.keybindingOverrides = overrides
    model.preferencesDraft!.recordingKeybindingFor = nil
    model.preferencesDraft!.keybindingConflict = nil
    model.preferencesDraft!.keybindingDiagnostic = nil
    return changed ? [.saveDanTermConfig(model.config)] : []
}
