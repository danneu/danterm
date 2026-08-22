// Pure Settings transactions for editing and validating the effective keybinding map.
import DanTermProtocol

/// Applies one legacy browser edit or one transition in the transactional sheet.
func updateKeybindingPreferences(
    _ model: inout AppModel,
    edit: KeybindingPreferenceEdit
) -> [Command] {
    guard model.preferencesDraft != nil else { return [] }

    switch edit {
    case .selectBrowserAction(let id):
        if let id, commandCatalog.contains(where: { $0.id == id }) == false { return [] }
        model.preferencesDraft!.selectedKeybindingAction = id
        return []

    case .openEditor(let id):
        guard let descriptor = commandCatalog.first(where: { $0.id == id }) else { return [] }
        let committed = catalogBindings(overrides: model.config.keybindingOverrides)[id, default: []]
        let isInitiallyDisabled = model.config.keybindingOverrides.chordsByAction[id]?.isEmpty == true
        var candidate = model.config.keybindingOverrides
        let isHeldMRU = isHeldMRUCommand(descriptor)
        let visible = isHeldMRU ? Array(committed.prefix(1)) : committed
        if isHeldMRU, committed.count > 1 {
            candidate.chordsByAction[id] = visible
        }
        model.preferencesDraft!.selectedKeybindingAction = id
        model.preferencesDraft!.keybindingEditor = KeybindingEditorDraft(
            actionID: id,
            candidate: candidate,
            retainedChords: isInitiallyDisabled ? descriptor.defaultChords : visible,
            recordingTarget: nil,
            diagnostic: nil,
            removedHeldMRUShortcutCount: max(0, committed.count - visible.count)
        )
        return []

    case .closeEditor:
        model.preferencesDraft!.keybindingEditor = nil
        return []

    case .beginEditorRecording(let index):
        guard var editor = model.preferencesDraft!.keybindingEditor else { return [] }
        let chords = editorDisplayedChords(editor)
        if let index, chords.indices.contains(index) == false { return [] }
        editor.recordingTarget = index.map(KeybindingEditorRecordingTarget.replacing) ?? .adding
        editor.diagnostic = nil
        model.preferencesDraft!.keybindingEditor = editor
        return []

    case .cancelEditorRecording:
        model.preferencesDraft!.keybindingEditor?.recordingTarget = nil
        model.preferencesDraft!.keybindingEditor?.diagnostic = nil
        return []

    case .rejectEditorRecording(let diagnostic):
        guard model.preferencesDraft!.keybindingEditor?.recordingTarget != nil else { return [] }
        model.preferencesDraft!.keybindingEditor?.diagnostic = diagnostic
        return []

    case .recordEditorChord(let chord):
        guard var editor = model.preferencesDraft!.keybindingEditor,
              let target = editor.recordingTarget
        else { return [] }
        var chords = editorDisplayedChords(editor)
        if chords.contains(chord) {
            editor.diagnostic = editorDiagnostic(
                editor.actionID,
                reason: "already assigned to this command"
            )
            model.preferencesDraft!.keybindingEditor = editor
            return []
        }
        if let reservation = keybindingReservations.first(where: { $0.chord == chord }) {
            editor.diagnostic = editorDiagnostic(editor.actionID, reason: "reserved by \(reservation.title)")
            model.preferencesDraft!.keybindingEditor = editor
            return []
        }
        switch target {
        case .adding:
            chords.append(chord)
        case .replacing(let index):
            guard chords.indices.contains(index) else { return [] }
            chords[index] = chord
        }
        if let diagnostic = stageEditorChords(chords, editor: &editor) {
            editor.diagnostic = diagnostic
            model.preferencesDraft!.keybindingEditor = editor
            return []
        }
        editor.retainedChords = chords
        editor.recordingTarget = nil
        editor.diagnostic = nil
        model.preferencesDraft!.keybindingEditor = editor
        return []

    case .removeEditorChord(let index):
        guard var editor = model.preferencesDraft!.keybindingEditor,
              editorAllowsMultipleChords(editor),
              var chords = catalogBindings(overrides: editor.candidate)[editor.actionID],
              chords.indices.contains(index)
        else { return [] }
        chords.remove(at: index)
        editor.candidate.chordsByAction[editor.actionID] = chords
        editor.retainedChords = chords
        editor.recordingTarget = nil
        editor.diagnostic = nil
        model.preferencesDraft!.keybindingEditor = editor
        return []

    case .makeEditorChordPrimary(let index):
        guard var editor = model.preferencesDraft!.keybindingEditor,
              editorAllowsMultipleChords(editor),
              var chords = catalogBindings(overrides: editor.candidate)[editor.actionID],
              chords.indices.contains(index)
        else { return [] }
        let chord = chords.remove(at: index)
        chords.insert(chord, at: 0)
        editor.candidate.chordsByAction[editor.actionID] = chords
        editor.retainedChords = chords
        editor.diagnostic = nil
        model.preferencesDraft!.keybindingEditor = editor
        return []

    case .setEditorEnabled(let enabled):
        guard var editor = model.preferencesDraft!.keybindingEditor else { return [] }
        if enabled {
            if let diagnostic = stageEditorChords(editor.retainedChords, editor: &editor) {
                editor.diagnostic = diagnostic
            } else {
                editor.diagnostic = nil
            }
        } else {
            let active = catalogBindings(overrides: editor.candidate)[editor.actionID, default: []]
            if active.isEmpty == false { editor.retainedChords = active }
            editor.candidate.chordsByAction[editor.actionID] = []
            editor.recordingTarget = nil
            editor.diagnostic = nil
        }
        model.preferencesDraft!.keybindingEditor = editor
        return []

    case .resetEditor:
        guard var editor = model.preferencesDraft!.keybindingEditor,
              let descriptor = commandCatalog.first(where: { $0.id == editor.actionID })
        else { return [] }
        let defaults = isHeldMRUCommand(descriptor)
            ? Array(descriptor.defaultChords.prefix(1)) : descriptor.defaultChords
        if let diagnostic = stageEditorChords(defaults, editor: &editor) {
            editor.diagnostic = diagnostic
        } else {
            editor.candidate.chordsByAction[editor.actionID] = nil
            editor.retainedChords = defaults
            editor.recordingTarget = nil
            editor.diagnostic = nil
        }
        model.preferencesDraft!.keybindingEditor = editor
        return []

    case .acceptEditor:
        guard let editor = model.preferencesDraft!.keybindingEditor else { return [] }
        let result = effectiveBindings(overrides: editor.candidate)
        guard result.value != nil else {
            model.preferencesDraft!.keybindingEditor?.diagnostic = result.diagnostics.first
            return []
        }
        let changed = editor.candidate != model.config.keybindingOverrides
        model.config.keybindingOverrides = editor.candidate
        model.preferencesDraft!.config.keybindingOverrides = editor.candidate
        model.preferencesDraft!.keybindingEditor = nil
        return changed ? [.saveDanTermConfig(model.config)] : []

    case .requestResetAll:
        model.preferencesDraft!.isResetAllKeybindingsConfirmationPresented = true
        return []

    case .cancelResetAll:
        model.preferencesDraft!.isResetAllKeybindingsConfirmationPresented = false
        return []

    case .confirmResetAll:
        guard model.preferencesDraft!.isResetAllKeybindingsConfirmationPresented else { return [] }
        model.preferencesDraft!.isResetAllKeybindingsConfirmationPresented = false
        let known = Set(commandCatalog.map(\.id))
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction = overrides.chordsByAction.filter { known.contains($0.key) == false }
        return validateAndCommit(&model, overrides)

    case .beginRecording(let id):
        guard commandCatalog.contains(where: { $0.id == id }) else { return [] }
        model.preferencesDraft!.recordingKeybindingFor = id
        model.preferencesDraft!.recordingKeybindingChordIndex = nil
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = nil
        return []

    case .beginReplacing(let id, let index):
        guard commandCatalog.contains(where: { $0.id == id }),
              effectiveBindings(overrides: model.config.keybindingOverrides).value?[id]?.indices.contains(index) == true
        else { return [] }
        model.preferencesDraft!.recordingKeybindingFor = id
        model.preferencesDraft!.recordingKeybindingChordIndex = index
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = nil
        return []

    case .cancelRecording:
        model.preferencesDraft!.recordingKeybindingFor = nil
        model.preferencesDraft!.recordingKeybindingChordIndex = nil
        model.preferencesDraft!.keybindingConflict = nil
        model.preferencesDraft!.keybindingDiagnostic = nil
        return []

    case .rejectRecording(let diagnostic):
        model.preferencesDraft!.recordingKeybindingFor = nil
        model.preferencesDraft!.recordingKeybindingChordIndex = nil
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
        if let index = conflict.replacementIndex, destination.indices.contains(index) {
            destination.remove(at: index)
        }
        if destination.contains(conflict.chord) == false {
            let insertion = min(conflict.replacementIndex ?? destination.endIndex, destination.endIndex)
            destination.insert(conflict.chord, at: insertion)
        }
        overrides.chordsByAction[conflict.destination] = destination
        return validateAndCommit(&model, overrides)

    case .record(let chord, let id, let replacementIndex):
        guard let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              var destination = bindings[id],
              replacementIndex.map({ destination.indices.contains($0) }) ?? true
        else { return [] }
        if let owner = bindings.first(where: { $0.key != id && $0.value.contains(chord) })?.key {
            model.preferencesDraft!.recordingKeybindingFor = nil
            model.preferencesDraft!.recordingKeybindingChordIndex = nil
            model.preferencesDraft!.keybindingDiagnostic = nil
            model.preferencesDraft!.keybindingConflict = KeybindingConflict(
                chord: chord,
                source: owner,
                destination: id,
                replacementIndex: replacementIndex
            )
            return []
        }
        if let index = replacementIndex { destination[index] = chord }
        else if destination.contains(chord) == false { destination.append(chord) }
        var overrides = model.config.keybindingOverrides
        overrides.chordsByAction[id] = destination
        return validateAndCommit(&model, overrides)

    case .add(let chord, let id):
        guard let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              let current = bindings[id]
        else { return [] }
        if current.contains(chord) {
            model.preferencesDraft!.recordingKeybindingFor = nil
            model.preferencesDraft!.recordingKeybindingChordIndex = nil
            return []
        }
        if let owner = bindings.first(where: { $0.key != id && $0.value.contains(chord) })?.key {
            model.preferencesDraft!.recordingKeybindingFor = nil
            model.preferencesDraft!.recordingKeybindingChordIndex = nil
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

/// Returns the inactive retained list while a sheet candidate disables its command.
private func editorDisplayedChords(_ editor: KeybindingEditorDraft) -> [KeyChord] {
    let active = catalogBindings(overrides: editor.candidate)[editor.actionID, default: []]
    return active.isEmpty ? editor.retainedChords : active
}

/// Reports whether the selected command supports alternate shortcut rows.
private func editorAllowsMultipleChords(_ editor: KeybindingEditorDraft) -> Bool {
    guard let descriptor = commandCatalog.first(where: { $0.id == editor.actionID }) else { return false }
    return isHeldMRUCommand(descriptor) == false
}

/// Identifies the two held-MRU commands whose modifiers must move as one transaction.
private func isHeldMRUCommand(_ descriptor: CommandDescriptor) -> Bool {
    if case .heldMRU = descriptor.gesture { return true }
    return false
}

/// Builds a sheet-local diagnostic at the selected command's stable config path.
private func editorDiagnostic(_ id: KeybindingActionID, reason: String) -> KeybindingDiagnostic {
    KeybindingDiagnostic(path: "keybindings.\(id.rawValue)", reason: reason)
}

/// Stages one selected list, moving ownership and held-MRU partner modifiers atomically.
private func stageEditorChords(
    _ chords: [KeyChord],
    editor: inout KeybindingEditorDraft
) -> KeybindingDiagnostic? {
    guard let descriptor = commandCatalog.first(where: { $0.id == editor.actionID }) else { return nil }
    if isHeldMRUCommand(descriptor), chords.count > 1 {
        return editorDiagnostic(editor.actionID, reason: "held MRU actions accept at most one chord")
    }
    if let reserved = chords.compactMap({ chord in
        keybindingReservations.first(where: { $0.chord == chord })
    }).first {
        return editorDiagnostic(editor.actionID, reason: "reserved by \(reserved.title)")
    }

    var candidate = editor.candidate
    moveCandidateOwnership(of: chords, to: editor.actionID, candidate: &candidate)
    candidate.chordsByAction[editor.actionID] = chords

    guard isHeldMRUCommand(descriptor), let chord = chords.first else {
        editor.candidate = candidate
        return nil
    }
    let partnerID: KeybindingActionID = editor.actionID == "tab.recent-older"
        ? "tab.recent-newer" : "tab.recent-older"
    guard let partner = catalogBindings(overrides: candidate)[partnerID]?.first,
          let pairedChord = KeyChord(modifiers: chord.modifiers, key: partner.key)
    else {
        editor.candidate = candidate
        return nil
    }
    if let reservation = keybindingReservations.first(where: { $0.chord == pairedChord }) {
        return editorDiagnostic(partnerID, reason: "reserved by \(reservation.title)")
    }
    moveCandidateOwnership(of: [pairedChord], to: partnerID, candidate: &candidate)
    candidate.chordsByAction[partnerID] = [pairedChord]
    editor.candidate = candidate
    return nil
}

/// Removes staged chords from every other catalog action before assigning a new owner.
private func moveCandidateOwnership(
    of chords: [KeyChord],
    to destination: KeybindingActionID,
    candidate: inout KeybindingOverrides
) {
    let moved = Set(chords)
    let bindings = catalogBindings(overrides: candidate)
    for descriptor in commandCatalog where descriptor.id != destination {
        let current = bindings[descriptor.id, default: []]
        let remaining = current.filter { moved.contains($0) == false }
        if remaining != current {
            candidate.chordsByAction[descriptor.id] = remaining
        }
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
        model.preferencesDraft!.recordingKeybindingChordIndex = nil
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
    model.preferencesDraft!.recordingKeybindingChordIndex = nil
    model.preferencesDraft!.keybindingConflict = nil
    model.preferencesDraft!.keybindingDiagnostic = nil
    return changed ? [.saveDanTermConfig(model.config)] : []
}
