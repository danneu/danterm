// The one AppKit controller behind every TODO popover, generic over the scope
// that supplies its rows and messages (see TodoPopoverScope.swift). It owns the
// whole algorithm exactly once: popover view assembly, projection apply with
// selection and first-responder preservation, list/edit mode transitions, the
// list key table, and the Cmd-key equivalents.
//
// Nothing here may branch on which scope is in play. A behavior that differs
// between the pane list and the tab list is a `TodoPopoverScope` requirement,
// not an `if`. Scope values themselves live with their cells and drag payloads
// in PaneTodoPopoverScope.swift and TabTodoPopoverScope.swift.

import Cocoa

/// Root view that lets the controller handle Cmd-key equivalents before AppKit
/// bubbles them to the window menu system.
final class TodoPopoverRootView: NSView {
    var handleKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Table subclass that routes list-mode keyboard commands through the popover
/// controller while leaving unhandled keys to NSTableView.
final class TodoPopoverTableView: NSTableView {
    var handleListKeyDown: ((NSEvent) -> Bool)?
    var handleCancelOperation: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleListKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if handleCancelOperation?() == true { return }
        super.cancelOperation(sender)
    }
}

/// Convert an AppKit key event's command/shift state into the pure TODO
/// shortcut classifier's modifier set.
func todoKeyModifiers(from event: NSEvent) -> KeyModifiers {
    var modifiers = KeyModifiers()
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    return modifiers
}

/// Convert an AppKit key event into the pure TODO list shortcut classifier's
/// key value, normalizing physical keys and printable characters.
func todoListKey(from event: NSEvent) -> ListKey {
    switch event.keyCode {
    case 36, 76:
        return .enter
    case 48:
        return event.modifierFlags.contains(.shift) ? .backtab : .tab
    case 49:
        return .space
    case 51:
        return .backspace
    case 125:
        return .downArrow
    case 126:
        return .upArrow
    default:
        break
    }

    switch event.charactersIgnoringModifiers?.lowercased() {
    case "h":
        return .h
    case "j":
        return .j
    case "k":
        return .k
    case "l":
        return .l
    case "/", "?":
        return .slash
    case "n":
        return .n
    default:
        return .other
    }
}

/// The TODO popover for one scope. It is `final` on purpose: a new TODO scope
/// is a new conforming value, never a subclass, so there is no override point
/// to get wrong. Every ObjC-facing member -- the `@objc` actions and the
/// table/text delegate methods -- stays in this class body, also on purpose:
/// Swift rejects both `@objc` members and `@objc` protocol conformances in an
/// extension of a generic class.
final class TodoPopoverController<Scope: TodoPopoverScope>: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    weak var runtime: AppRuntime?

    let tableView = TodoPopoverTableView()
    let scrollView = NSScrollView()
    let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    lazy var addInput: TodoInputView = {
        guard let placeholder = Scope.composePlaceholder else { return TodoInputView() }
        return TodoInputView(placeholder: placeholder)
    }()
    let editTitleLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Edit task")
        tf.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()
    let editInput = TodoInputView(placeholder: "Edit task...", visibleLineCount: TodoInputView.editVisibleLineCount)
    /// Built in `loadView`. The row owns the editor's buttons, so the focus
    /// restore and the key-view loop read them back instead of storing them.
    private var editButtons: DialogActionRow!
    var saveButton: NSButton { editButtons.button(for: .defaultAction)! }
    var cancelButton: NSButton { editButtons.button(for: .cancel)! }
    var bottomStack: NSStackView!
    var editContainer: NSStackView!
    var isSyncingTableSelection = false

    private var scope: Scope
    private var popoverState = TodoPopoverState<Scope.EditTarget>()
    /// The controller's view of `scope.rows`, refreshed with the projection so
    /// the table and every selection lookup read one consistent snapshot.
    private var rows: [TodoPopoverRow<Scope.EditTarget>]

    private let headerLabel = NSTextField(labelWithString: "")
    private let helpButton = NSButton()
    private let composeHintLabel = makeTodoShortcutHintLabel()
    private let editHintLabel = makeTodoShortcutHintLabel()
    private var extraHeaderButtons: [NSButton] = []
    private var emptyLabel: NSTextField?
    private var shortcutHelpPopover: NSPopover?

    var hasShortcutHelpPopover: Bool { shortcutHelpPopover != nil }

    var composeDraft: String {
        get { popoverState.composeDraft }
        set { popoverState.setComposeDraft(newValue) }
    }

    var isEditing: Bool { popoverState.isEditing }

    init(scope: Scope, runtime: AppRuntime?) {
        self.scope = scope
        self.rows = scope.rows
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let size = NSSize(width: 320, height: 400)
        preferredContentSize = size

        let wrapper = TodoPopoverRootView(frame: NSRect(origin: .zero, size: size))
        wrapper.handleKeyEquivalent = { [weak self] event in
            self?.performTodoKeyEquivalent(with: event) ?? false
        }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        headerLabel.stringValue = Scope.headerTitle
        headerLabel.font = .preferredFont(forTextStyle: .headline)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        extraHeaderButtons = Scope.headerComposeButtonTitles.map { title in
            let button = NSButton(title: title, target: self, action: #selector(focusComposeAction(_:)))
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }

        let headerActions = NSStackView(views: [clearButton] + extraHeaderButtons)
        headerActions.orientation = .horizontal
        headerActions.alignment = .centerY
        headerActions.spacing = 6
        headerActions.detachesHiddenViews = true
        headerActions.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerActions)

        configureTodoShortcutHelpButton(helpButton, target: self, action: #selector(toggleShortcutHelp(_:)))
        container.addSubview(helpButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Scope.tableColumnIdentifier))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableRowDoubleClicked(_:))
        tableView.handleListKeyDown = { [weak self] event in
            self?.handleListKeyDown(event) ?? false
        }
        tableView.handleCancelOperation = { [weak self] in
            self?.closePopoverFromList()
            return true
        }
        tableView.registerForDraggedTypes([Scope.dragType])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        if let message = Scope.emptyListMessage {
            let label = NSTextField(labelWithString: message)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            ])
            emptyLabel = label
        }

        editInput.textView.delegate = self

        // The row reserves no key equivalents: `editInput.textView` classifies
        // Return and Escape itself, and a default button claiming Return would
        // take the press before the text view sees it.
        editButtons = DialogActionRow(
            actions: [
                DialogAction(title: "Save", role: .defaultAction) { [weak self] in
                    self?.saveEditButtonClicked(nil)
                },
                DialogAction(title: "Cancel", role: .cancel) { [weak self] in
                    self?.cancelEditButtonClicked(nil)
                },
            ],
            reservesKeyEquivalents: false)

        editContainer = NSStackView(views: [editTitleLabel, editInput, editHintLabel, editButtons])
        editContainer.orientation = .vertical
        editContainer.alignment = .leading
        editContainer.spacing = 8
        editContainer.translatesAutoresizingMaskIntoConstraints = false
        editContainer.isHidden = true
        container.addSubview(editContainer)

        let sep = NSBox()
        sep.boxType = .separator

        addInput.textView.delegate = self

        bottomStack = NSStackView(views: [sep, addInput, composeHintLabel])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.detachesHiddenViews = true
        container.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),

            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerActions.leadingAnchor, constant: -8),
            headerActions.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            headerActions.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),
            helpButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            helpButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),

            editContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            editContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            editContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            editContainer.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            editInput.widthAnchor.constraint(equalTo: editContainer.widthAnchor),
            // The edit column is leading-aligned, so the row would otherwise get
            // only its fitting width and its trailing gravity nothing to pin to.
            editButtons.widthAnchor.constraint(equalTo: editContainer.widthAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            bottomStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bottomStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            sep.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
            addInput.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
        ])

        self.view = wrapper
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        apply(scope.projection)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusComposeInput()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        closeShortcutHelpPopover()
    }

    // MARK: - Projection apply

    /// Render the latest model projection while preserving view-local drafts,
    /// selection, and first responder when their targets still exist.
    func apply(_ newProjection: Scope.Projection) {
        let composeWasFirstResponder = view.window?.firstResponder === addInput.textView
        let editWasFirstResponder = view.window?.firstResponder === editInput.textView
        let tableWasFirstResponder = view.window?.firstResponder === tableView
        let saveWasFirstResponder = view.window?.firstResponder === saveButton
        let cancelWasFirstResponder = view.window?.firstResponder === cancelButton
        let selectedTarget = selectedEditTarget()
        let selectedRowBeforeReload = tableView.selectedRow
        let wasEditing = popoverState.isEditing
        let previousEditTarget = popoverState.editTarget
        let editDraft = editInput.string
        popoverState.setComposeDraft(addInput.string)

        scope.projection = newProjection
        rows = scope.rows
        popoverState.reconcileEditTarget { scope.resolve($0) }
        if let editTarget = popoverState.editTarget {
            editTitleLabel.stringValue = scope.editTitle(for: editTarget)
            if wasEditing,
               let previousEditTarget,
               scope.refersToSameTodo(previousEditTarget, editTarget) {
                editInput.string = editDraft
            } else if let item = item(for: editTarget) {
                editInput.string = item.text
            }
        }
        let resolvedSelectedTarget = selectedTarget.flatMap { scope.resolve($0) }
        syncModeVisibility()
        isSyncingTableSelection = true
        tableView.reloadData()
        if let target = popoverState.editTarget {
            if let newIndex = rowIndex(for: target) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        } else if let resolvedSelectedTarget,
                  let newIndex = rowIndex(for: resolvedSelectedTarget) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingTableSelection = false

        if (wasEditing && !popoverState.isEditing) || (selectedTarget != nil && resolvedSelectedTarget == nil) {
            selectNearestSelectableRow(near: selectedRowBeforeReload, focus: false)
        }
        restoreFirstResponder(
            composeWasFirstResponder: composeWasFirstResponder,
            editWasFirstResponder: editWasFirstResponder,
            tableWasFirstResponder: tableWasFirstResponder,
            saveWasFirstResponder: saveWasFirstResponder,
            cancelWasFirstResponder: cancelWasFirstResponder
        )
    }

    func syncModeVisibility() {
        let editMode = popoverState.isEditing
        clearButton.isHidden = editMode || !scope.hasCompleted
        for button in extraHeaderButtons { button.isHidden = editMode }
        editContainer.isHidden = !editMode
        scrollView.isHidden = editMode || (emptyLabel != nil && rows.isEmpty)
        emptyLabel?.isHidden = editMode || !rows.isEmpty
        bottomStack.isHidden = editMode
        if editMode {
            installEditKeyLoop()
        } else {
            tearDownEditKeyLoop()
            addInput.string = popoverState.composeDraft
        }
    }

    // MARK: - Rows and selection

    private func selectedEditTarget() -> Scope.EditTarget? {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return nil }
        return rows[row].editTarget
    }

    private func item(for target: Scope.EditTarget) -> TodoItem? {
        rows.first { $0.editTarget == target }?.item
    }

    private func rowIndex(for target: Scope.EditTarget) -> Int? {
        rows.firstIndex { $0.editTarget == target }
    }

    private func setSelectedRow(_ row: Int) {
        guard rows.indices.contains(row), rows[row].isSelectable else { return }
        isSyncingTableSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        isSyncingTableSelection = false
    }

    @discardableResult
    private func selectTarget(_ target: Scope.EditTarget) -> Bool {
        guard let row = rowIndex(for: target) else { return false }
        setSelectedRow(row)
        return true
    }

    /// Select the row `target` names now, following the todo if the scope says
    /// it moved. Used wherever selection is restored across a mutation.
    @discardableResult
    private func selectResolvedTarget(_ target: Scope.EditTarget) -> Bool {
        guard let resolved = scope.resolve(target) else { return false }
        return selectTarget(resolved)
    }

    private func selectNearestSelectableRow(near row: Int, focus: Bool = true) {
        if rows.indices.contains(row), rows[row].isSelectable {
            setSelectedRow(row)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if let next = nextSelectableRow(in: rows, from: row, delta: 1, canSelect: { $0.isSelectable }) {
            setSelectedRow(next)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if let previous = nextSelectableRow(in: rows, from: min(row, rows.count), delta: -1, canSelect: { $0.isSelectable }) {
            setSelectedRow(previous)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if focus {
            focusComposeInput()
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Dispatch a mutation, then put selection back on the row it was on. These
    /// helpers run only from top-of-stack user events, so no send frame is open and
    /// production reconciles synchronously before the lookup.
    private func dispatch(_ msg: Msg, restoring target: Scope.EditTarget?) {
        runtime?.send(msg)
        if let target { selectResolvedTarget(target) }
    }

    /// Dispatch a scope-computed mutation and select the row it names.
    private func dispatch(_ mutation: TodoPopoverMutation<Scope.EditTarget>) {
        runtime?.send(mutation.msg)
        selectTarget(mutation.select)
    }

    // MARK: - Focus and edit transitions

    @discardableResult
    func focusListFromInput() -> Bool {
        popoverState.setComposeDraft(addInput.string)
        var row = tableView.selectedRow
        if !rows.indices.contains(row) || !rows[row].isSelectable {
            guard let firstRow = firstSelectableRow(in: rows, canSelect: { $0.isSelectable }) else { return false }
            row = firstRow
        }
        setSelectedRow(row)
        popoverState.selectRow(selectedEditTarget())
        syncModeVisibility()
        view.window?.makeFirstResponder(tableView)
        return true
    }

    func focusComposeInput() {
        addInput.string = popoverState.composeDraft
        syncModeVisibility()
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.moveToEndOfDocument(nil)
    }

    func focusComposeFromShortcut() {
        if isEditing {
            guard saveEditThenReturnToList() else { return }
            popoverState.clearComposeDraft()
        }
        focusComposeInput()
    }

    func enterEditForSelectedRow() {
        guard let target = selectedEditTarget(), let item = item(for: target) else { return }
        popoverState.enterEdit(target: target, itemText: item.text)
        editInput.string = item.text
        editTitleLabel.stringValue = scope.editTitle(for: target)
        syncModeVisibility()
        view.window?.makeFirstResponder(editInput.textView)
        editInput.textView.moveToEndOfDocument(nil)
    }

    @discardableResult
    func saveEditThenReturnToList() -> Bool {
        switch popoverState.saveEdit(text: editInput.string) {
        case .saved(let target, let text):
            runtime?.send(scope.editMsg(target: target, text: text))
            syncModeVisibility()
            selectResolvedTarget(target)
            view.window?.makeFirstResponder(tableView)
            return true
        case .rejected:
            view.window?.makeFirstResponder(editInput.textView)
            return false
        }
    }

    func cancelEditAndReturnToList() {
        guard let target = popoverState.editTarget else { return }
        popoverState.cancelEdit()
        syncModeVisibility()
        if selectResolvedTarget(target) {
            view.window?.makeFirstResponder(tableView)
        } else {
            focusListFromInput()
        }
    }

    func addTodoAndStayInCompose() {
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let context = scope.addContext()
        runtime?.send(scope.addMsg(text: text))
        popoverState.clearComposeDraft()
        addInput.string = ""
        if let target = scope.targetAfterAdd(context) {
            selectTarget(target)
        }
        view.window?.makeFirstResponder(addInput.textView)
    }

    func closePopoverFromList() {
        runtime?.send(scope.dismissMsg())
    }

    private func restoreFirstResponder(
        composeWasFirstResponder: Bool,
        editWasFirstResponder: Bool,
        tableWasFirstResponder: Bool,
        saveWasFirstResponder: Bool,
        cancelWasFirstResponder: Bool
    ) {
        guard let window = view.window else { return }
        if isEditing {
            if editWasFirstResponder {
                window.makeFirstResponder(editInput.textView)
            } else if saveWasFirstResponder {
                window.makeFirstResponder(saveButton)
            } else if cancelWasFirstResponder {
                window.makeFirstResponder(cancelButton)
            }
            return
        }
        if editWasFirstResponder || saveWasFirstResponder || cancelWasFirstResponder {
            if tableView.selectedRow >= 0 {
                window.makeFirstResponder(tableView)
            } else {
                focusComposeInput()
            }
            return
        }
        if composeWasFirstResponder {
            window.makeFirstResponder(addInput.textView)
        } else if tableWasFirstResponder {
            if tableView.selectedRow >= 0 {
                window.makeFirstResponder(tableView)
            } else {
                focusComposeInput()
            }
        }
    }

    /// Tab order follows the drawn order, so the loop cannot disagree with the
    /// layout the action row chose.
    private func installEditKeyLoop() {
        let chain: [NSView] = [editInput.textView] + editButtons.buttonsInVisualOrder
        for (view, next) in zip(chain, chain.dropFirst() + [chain[0]]) {
            view.nextKeyView = next
        }
    }

    private func tearDownEditKeyLoop() {
        for view in [editInput.textView] + editButtons.buttonsInVisualOrder {
            view.nextKeyView = nil
        }
    }

    // MARK: - List actions

    private func toggleSelectedTodoDone() {
        guard let target = selectedEditTarget() else { return }
        dispatch(scope.toggleDoneMsg(target: target), restoring: target)
        view.window?.makeFirstResponder(tableView)
    }

    private func deleteSelectedTodo() {
        let row = tableView.selectedRow
        guard let target = selectedEditTarget() else { return }
        runtime?.send(scope.deleteMsg(target: target))
        selectNearestSelectableRow(near: row)
    }

    private func reorderSelectedTodo(delta: Int) {
        guard let mutation = scope.reorder(atRow: tableView.selectedRow, delta: delta) else { return }
        dispatch(mutation)
        view.window?.makeFirstResponder(tableView)
    }

    private func moveSelection(delta: Int) {
        let row = tableView.selectedRow
        guard let nextRow = nextSelectableRow(in: rows, from: row, delta: delta, canSelect: { $0.isSelectable }) else { return }
        setSelectedRow(nextRow)
    }

    /// Returns whether this scope claims the key at all, which is what decides
    /// if Shift-H/L bubbles out of the popover.
    private func moveSelectedTodoToAdjacentBucket(delta: Int) -> Bool {
        guard Scope.handlesBucketMoves else { return false }
        guard view.window?.firstResponder === tableView || isEditing else { return false }
        if isEditing {
            _ = saveEditThenReturnToList()
        }
        guard let current = selectedEditTarget(),
              let mutation = scope.bucketMove(from: current, delta: delta) else { return true }
        dispatch(mutation)
        view.window?.makeFirstResponder(tableView)
        return true
    }

    func handleListKeyDown(_ event: NSEvent) -> Bool {
        let action = classifyListAction(key: todoListKey(from: event), modifiers: todoKeyModifiers(from: event))
        switch action {
        case .moveSelection(let delta):
            moveSelection(delta: delta)
            return true
        case .enterEdit:
            enterEditForSelectedRow()
            return true
        case .toggleDone:
            toggleSelectedTodoDone()
            return true
        case .deleteRow:
            deleteSelectedTodo()
            return true
        case .reorder(let delta):
            reorderSelectedTodo(delta: delta)
            return true
        case .moveBucket(let delta):
            return moveSelectedTodoToAdjacentBucket(delta: delta)
        case .focusInput:
            focusComposeInput()
            return true
        case .showShortcutHelp:
            toggleShortcutHelp(nil)
            return true
        case .unhandled:
            return false
        }
    }

    func performTodoKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = todoKeyModifiers(from: event)
        let key = todoListKey(from: event)
        if classifyListAction(key: key, modifiers: modifiers) == .showShortcutHelp {
            toggleShortcutHelp(nil)
            return true
        }
        if modifiers == [.command, .shift] {
            guard Scope.handlesBucketMoves else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h", "l":
                return true
            default:
                return false
            }
        }

        guard modifiers == [.command] else { return false }
        switch key {
        case .enter:
            if isEditing {
                _ = saveEditThenReturnToList()
            } else if view.window?.firstResponder === addInput.textView {
                addTodoAndStayInCompose()
            }
            return true
        case .n:
            focusComposeFromShortcut()
            return true
        case .backspace:
            guard view.window?.firstResponder === tableView else { return false }
            deleteSelectedTodo()
            return true
        default:
            return false
        }
    }

    // MARK: - Shortcut help

    /// Close shortcut help before the parent popover closes or reanchors.
    func closeShortcutHelpPopover() {
        guard let popover = shortcutHelpPopover else { return }
        shortcutHelpPopover = nil
        popover.performClose(nil)
    }

    /// Show help as a child popover while preserving parent click-away state.
    private func showShortcutHelpPopover() {
        guard shortcutHelpPopover == nil else {
            closeShortcutHelpPopover()
            return
        }
        guard let parentPopover = runtime?.todoPopover else { return }
        let savedResponder = view.window?.firstResponder
        let popover = NSPopover()
        let controller = TodoShortcutHelpViewController(
            scope: Scope.shortcutHelpScope,
            parentPopover: parentPopover,
            parentView: view,
            savedResponder: savedResponder
        ) { [weak self, weak popover] in
            guard let self, self.shortcutHelpPopover === popover else { return }
            self.shortcutHelpPopover = nil
        }
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.delegate = controller
        controller.popover = popover
        parentPopover.behavior = .applicationDefined
        shortcutHelpPopover = popover
        popover.show(relativeTo: helpButton.bounds, of: helpButton, preferredEdge: .minY)
    }

    // MARK: - ObjC actions

    @objc func focusComposeAction(_ sender: Any?) {
        focusComposeFromShortcut()
    }

    @objc func tableRowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        enterEditForSelectedRow()
    }

    @objc func saveEditButtonClicked(_ sender: Any?) {
        _ = saveEditThenReturnToList()
    }

    @objc func cancelEditButtonClicked(_ sender: Any?) {
        cancelEditAndReturnToList()
    }

    @objc func toggleShortcutHelp(_ sender: Any?) {
        if shortcutHelpPopover != nil {
            closeShortcutHelpPopover()
        } else {
            showShortcutHelpPopover()
        }
    }

    @objc func clearCompleted() {
        dispatch(scope.clearCompletedMsg(), restoring: selectedEditTarget())
    }

    @objc func checkboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard rows.indices.contains(row),
              let target = rows[row].editTarget,
              let item = rows[row].item else { return }
        dispatch(scope.checkboxMsg(target: target, isDone: !item.isDone), restoring: selectedEditTarget())
    }

    @objc func deleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard rows.indices.contains(row), let target = rows[row].editTarget else { return }
        dispatch(scope.deleteMsg(target: target), restoring: selectedEditTarget())
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        scope.pasteboardWriter(atRow: row)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        scope.validateDrop(proposedRow: row, operation: dropOperation)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let runtime,
              let drop = scope.acceptDrop(
                  pasteboard: info.draggingPasteboard,
                  row: row,
                  operation: dropOperation
              ) else { return false }
        let previousTarget = selectedEditTarget()
        runtime.send(drop.msg)
        switch drop.selection {
        case .restorePrevious:
            if let previousTarget { selectResolvedTarget(previousTarget) }
        case .target(let target):
            selectTarget(target)
        }
        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        scope.cellView(
            atRow: row,
            in: tableView,
            actions: TodoPopoverCellActions(
                target: self,
                checkbox: #selector(checkboxToggled(_:)),
                delete: #selector(deleteTask(_:))
            )
        )
    }

    /// NSTableViewDelegate: keep button clicks from selecting the row, let the
    /// scope run any click side effect, then select only real item rows.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown,
           let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let localPoint = rowView.convert(point, from: tableView)
            if let hit = rowView.hitTest(localPoint), hit is NSButton { return false }
        }
        switch scope.rowClick(atRow: row) {
        case .focusPane(let paneId):
            runtime?.focusPaneSession(paneId)
            view.window?.close()
            return false
        case .ignored:
            break
        }
        guard rows.indices.contains(row) else { return false }
        return rows[row].isSelectable
    }

    /// NSTableViewDelegate: render section headers with AppKit's group-row style.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row].isHeader
    }

    /// NSTableViewDelegate: row selection stays in list mode and never edits
    /// the compose draft.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row), let target = rows[row].editTarget else { return }
        popoverState.selectRow(target)
    }

    // MARK: - NSTextViewDelegate

    /// NSTextViewDelegate: route keyboard commands through the pure classifier.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === addInput.textView || textView === editInput.textView else { return false }
        if commandSelector == #selector(insertNewline(_:)),
           let event = NSApp.currentEvent,
           event.modifierFlags.contains(.command) {
            return performTodoKeyEquivalent(with: event)
        }
        if commandSelector == #selector(deleteBackward(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            return false
        }

        let key: InputKey
        if commandSelector == #selector(insertNewline(_:)) {
            key = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .shiftEnter : .enter
        } else if commandSelector == #selector(cancelOperation(_:)) {
            key = .escape
        } else if commandSelector == #selector(deleteBackward(_:)) {
            key = .backspace
        } else if commandSelector == #selector(insertTab(_:)) {
            key = .tab
        } else if commandSelector == #selector(insertBacktab(_:)) {
            key = .backtab
        } else {
            key = .other
        }

        let action = classifyInputAction(
            key: key,
            isEditing: isEditing,
            fieldEmpty: textView.string.isEmpty
        )

        switch action {
        case .submit:
            if isEditing {
                _ = saveEditThenReturnToList()
            } else {
                addTodoAndStayInCompose()
            }
            return true
        case .insertNewline:
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case .cancelEdit:
            cancelEditAndReturnToList()
            return true
        case .dismiss:
            if !focusListFromInput() {
                closePopoverFromList()
            }
            return true
        case .moveFocusForward:
            if isEditing {
                view.window?.selectNextKeyView(nil)
            } else {
                _ = focusListFromInput()
            }
            return true
        case .moveFocusBackward:
            if isEditing {
                view.window?.selectPreviousKeyView(nil)
            } else {
                _ = focusListFromInput()
            }
            return true
        case .unhandled:
            if key == .backtab { return true }
            return false
        }
    }

    /// NSTextViewDelegate: keep the compose draft live while adding a new item.
    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === addInput.textView else { return }
        guard !isEditing else { return }
        composeDraft = addInput.string
    }
}

// MARK: - Outward seam

extension TodoPopoverController: TodoPopoverApplying {
    func apply(_ projection: TodoPopoverProjection) {
        guard let mine = Scope.projection(from: projection) else { return }
        apply(mine)
    }
}
