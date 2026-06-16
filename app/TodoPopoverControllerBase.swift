// Shared AppKit controller chrome for pane and tab TODO popovers. This file
// owns only the behavior that is independent of TODO scope and row shape:
// popover view assembly, text-field command routing, shortcut help lifetime,
// and list/edit focus plumbing. Keep projection-specific state, table rows,
// drag payloads, and Msg routing in the concrete pane/tab controllers.

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

/// Non-generic base for AppKit-dispatched TODO popover controller plumbing.
/// Keeping ObjC-visible delegate and action methods on a concrete class avoids
/// generic Swift/ObjC dispatch pitfalls while concrete subclasses own typed
/// state and projection-specific table behavior.
class TodoPopoverControllerBase: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?

    let tableView = TodoPopoverTableView()
    let scrollView = NSScrollView()
    let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    lazy var addInput: TodoInputView = {
        guard let placeholder = composePlaceholder else { return TodoInputView() }
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
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var bottomStack: NSStackView!
    var editContainer: NSStackView!
    var isSyncingTableSelection = false

    private let headerLabel = NSTextField(labelWithString: "")
    private let helpButton = NSButton()
    private let composeHintLabel = makeTodoShortcutHintLabel()
    private let editHintLabel = makeTodoShortcutHintLabel()
    private var shortcutHelpPopover: NSPopover?

    var hasShortcutHelpPopover: Bool { shortcutHelpPopover != nil }

    init(runtime: AppRuntime?) {
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

        headerLabel.stringValue = headerTitle
        headerLabel.font = .preferredFont(forTextStyle: .headline)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let headerActions = NSStackView(views: headerActionButtons())
        headerActions.orientation = .horizontal
        headerActions.alignment = .centerY
        headerActions.spacing = 6
        headerActions.detachesHiddenViews = true
        headerActions.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerActions)

        configureTodoShortcutHelpButton(helpButton, target: self, action: #selector(toggleShortcutHelp(_:)))
        container.addSubview(helpButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(tableColumnIdentifier))
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
        registerDragTypes(on: tableView)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        installEmptyState(in: container)

        saveButton.target = self
        saveButton.action = #selector(saveEditButtonClicked(_:))
        saveButton.bezelStyle = .rounded

        cancelButton.target = self
        cancelButton.action = #selector(cancelEditButtonClicked(_:))
        cancelButton.bezelStyle = .rounded

        editInput.textView.delegate = self

        let editButtons = NSStackView(views: [saveButton, cancelButton])
        editButtons.orientation = .horizontal
        editButtons.alignment = .centerY
        editButtons.spacing = 8

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
        applyStoredProjection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInitialMode()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        closeShortcutHelpPopover()
    }

    var composeDraft: String {
        get { fatalError("subclass must override") } // override point
        set { fatalError("subclass must override") } // override point
    }

    func clearComposeDraft() {
        fatalError("subclass must override") // override point
    }

    var isEditing: Bool {
        fatalError("subclass must override") // override point
    }

    func applyStoredProjection() {
        fatalError("subclass must override") // override point
    }

    @discardableResult
    func saveEditThenReturnToList() -> Bool {
        fatalError("subclass must override") // override point
    }

    func addTodoAndStayInCompose() {
        fatalError("subclass must override") // override point
    }

    func cancelEditAndReturnToList() {
        fatalError("subclass must override") // override point
    }

    func enterEditForSelectedRow() {
        fatalError("subclass must override") // override point
    }

    @discardableResult
    func focusListFromInput() -> Bool {
        fatalError("subclass must override") // override point
    }

    func closePopoverFromList() {
        fatalError("subclass must override") // override point
    }

    func handleListKeyDown(_ event: NSEvent) -> Bool {
        fatalError("subclass must override") // override point
    }

    func performTodoKeyEquivalent(with event: NSEvent) -> Bool {
        fatalError("subclass must override") // override point
    }

    func syncModeVisibility() {
        fatalError("subclass must override") // override point
    }

    var parentTodoPopover: NSPopover? {
        fatalError("subclass must override") // override point
    }

    var shortcutHelpScope: TodoShortcutScope {
        fatalError("subclass must override") // override point
    }

    @objc func clearCompleted() {
        fatalError("subclass must override") // override point
    }

    var headerTitle: String {
        fatalError("subclass must override") // override point
    }

    func headerActionButtons() -> [NSView] {
        [clearButton]
    }

    var composePlaceholder: String? { nil }

    var tableColumnIdentifier: String {
        fatalError("subclass must override") // override point
    }

    func registerDragTypes(on tableView: NSTableView) {
        fatalError("subclass must override") // override point
    }

    func installEmptyState(in container: NSView) {}

    func numberOfRows(in tableView: NSTableView) -> Int {
        fatalError("subclass must override") // override point
    }

    func restoreFirstResponder(
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

    func focusComposeInput() {
        addInput.string = composeDraft
        syncModeVisibility()
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.moveToEndOfDocument(nil)
    }

    func saveEditThenFocusCompose(clearingDraft: Bool) {
        guard saveEditThenReturnToList() else { return }
        if clearingDraft {
            clearComposeDraft()
        }
        focusComposeInput()
    }

    func focusComposeFromShortcut() {
        if isEditing {
            saveEditThenFocusCompose(clearingDraft: true)
        } else {
            focusComposeInput()
        }
    }

    func installEditKeyLoop() {
        editInput.textView.nextKeyView = saveButton
        saveButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = editInput.textView
    }

    func tearDownEditKeyLoop() {
        editInput.textView.nextKeyView = nil
        saveButton.nextKeyView = nil
        cancelButton.nextKeyView = nil
    }

    private func focusInitialMode() {
        focusComposeInput()
    }

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
        guard let parentPopover = parentTodoPopover else { return }
        let savedResponder = view.window?.firstResponder
        let popover = NSPopover()
        let controller = TodoShortcutHelpViewController(
            scope: shortcutHelpScope,
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
}

// MARK: - NSTextViewDelegate

extension TodoPopoverControllerBase: NSTextViewDelegate {
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
