// Search overlay view positioned at the top-right of a pane. Contains a native
// NSSearchField with match counter, prev/next navigation buttons, and close.
import Cocoa

class SearchOverlayView: NSView, NSSearchFieldDelegate {
    let searchField: NSSearchField
    private let counterLabel: NSTextField
    private let prevButton: NSButton
    private let nextButton: NSButton
    private let closeButton: NSButton
    private let backgroundView: NSVisualEffectView
    private var counterWidthConstraint: NSLayoutConstraint!
    private var counterToButtonsConstraint: NSLayoutConstraint!

    let paneId: PaneId
    private weak var runtime: AppRuntime?

    init(paneId: PaneId, runtime: AppRuntime?) {
        self.paneId = paneId
        self.runtime = runtime

        // Background
        backgroundView = NSVisualEffectView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 0.5
        backgroundView.layer?.borderColor = NSColor.separatorColor.cgColor

        // Native search field
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search..."
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.cell?.sendsActionOnEndEditing = false

        // Counter label (fixed width, right-aligned)
        counterLabel = NSTextField(labelWithString: "")
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.alignment = .right
        counterLabel.lineBreakMode = .byClipping
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Prev button (chevron up)
        prevButton = NSButton()
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        prevButton.bezelStyle = .inline
        prevButton.isBordered = false
        prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")
        prevButton.imageScaling = .scaleProportionallyDown
        prevButton.contentTintColor = .secondaryLabelColor
        prevButton.setContentHuggingPriority(.required, for: .horizontal)

        // Next button (chevron down)
        nextButton = NSButton()
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.bezelStyle = .inline
        nextButton.isBordered = false
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")
        nextButton.imageScaling = .scaleProportionallyDown
        nextButton.contentTintColor = .secondaryLabelColor
        nextButton.setContentHuggingPriority(.required, for: .horizontal)

        // Close button (xmark)
        closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close search")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        searchField.delegate = self
        prevButton.target = self
        prevButton.action = #selector(prevMatch)
        nextButton.target = self
        nextButton.action = #selector(nextMatch)
        closeButton.target = self
        closeButton.action = #selector(closeSearch)

        addSubview(backgroundView)
        backgroundView.addSubview(searchField)
        backgroundView.addSubview(counterLabel)

        let buttonStack = NSStackView(views: [prevButton, nextButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 2
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(buttonStack)

        let buttonSize: CGFloat = 16
        counterWidthConstraint = counterLabel.widthAnchor.constraint(equalToConstant: 56)
        counterToButtonsConstraint = buttonStack.leadingAnchor.constraint(equalTo: counterLabel.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchField.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            counterLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            counterLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            counterWidthConstraint,

            counterToButtonsConstraint,
            buttonStack.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -8),

            prevButton.widthAnchor.constraint(equalToConstant: buttonSize),
            prevButton.heightAnchor.constraint(equalToConstant: buttonSize),
            nextButton.widthAnchor.constraint(equalToConstant: buttonSize),
            nextButton.heightAnchor.constraint(equalToConstant: buttonSize),
            closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: buttonSize),

            heightAnchor.constraint(equalToConstant: 32),
        ])

        setCounterVisible(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Refresh the counter label and text field from model state.
    func update(search: SearchModel) {
        if searchField.stringValue != search.needle {
            searchField.stringValue = search.needle
        }
        if search.needle.isEmpty {
            counterLabel.stringValue = ""
            counterLabel.textColor = .secondaryLabelColor
            setCounterVisible(false)
        } else if let total = search.total {
            if let selected = search.selected {
                counterLabel.stringValue = "\(selected + 1)/\(total)"
            } else {
                counterLabel.stringValue = "-/\(total)"
            }
            counterLabel.textColor = .secondaryLabelColor
            setCounterVisible(true)
        } else {
            if counterLabel.stringValue.isEmpty {
                counterLabel.stringValue = "--/--"
            }
            counterLabel.textColor = .tertiaryLabelColor
            setCounterVisible(true)
        }
    }

    /// Collapse the counter slot until the user has entered a query, then restore fixed-width layout.
    private func setCounterVisible(_ visible: Bool) {
        counterLabel.isHidden = !visible
        counterWidthConstraint.constant = visible ? 56 : 0
        counterToButtonsConstraint.constant = visible ? 8 : 0
    }

    // MARK: - NSSearchFieldDelegate

    // Dispatch needle changes as the user types.
    func controlTextDidChange(_ obj: Notification) {
        runtime?.send(.searchNeedleChanged(paneId: paneId, needle: searchField.stringValue))
    }

    // Handle Escape (close) and Enter (navigate next/prev with Shift).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            runtime?.send(.endSearch(paneId: paneId))
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            let direction: SearchDirection = shiftPressed ? .previous : .next
            runtime?.send(.searchNavigate(paneId: paneId, direction: direction))
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc private func prevMatch() {
        runtime?.send(.searchNavigate(paneId: paneId, direction: .previous))
    }

    @objc private func nextMatch() {
        runtime?.send(.searchNavigate(paneId: paneId, direction: .next))
    }

    @objc private func closeSearch() {
        runtime?.send(.endSearch(paneId: paneId))
    }
}
