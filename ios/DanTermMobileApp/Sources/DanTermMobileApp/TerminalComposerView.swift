// Owns terminal text entry, the compact key row, and keyboard dismissal.
import DanTermMobileKit
import UIKit

/// Keeps terminal input controls visible and adaptable on compact phone screens.
@MainActor
final class TerminalComposerView: UIView, UITextViewDelegate {
    var onText: ((String) -> Void)?
    var onPaste: ((String) -> Void)?
    var onAccessoryKey: ((MobileAccessoryKey) -> Bool)?
    var onDismissKeyboard: (() -> Void)?

    private let inputTextView = TerminalInputTextView()
    private let keyRow = UIStackView()
    private let keyboardDismissButton = UIButton(type: .system)
    private weak var controlButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func focusInput() {
        inputTextView.becomeFirstResponder()
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text.isEmpty == false { onText?(text) }
        return false
    }

    private func configureViews() {
        inputTextView.delegate = self
        inputTextView.onPaste = { [weak self] text in self?.onPaste?(text) }
        inputTextView.autocorrectionType = .no
        inputTextView.autocapitalizationType = .none
        inputTextView.smartDashesType = .no
        inputTextView.smartQuotesType = .no
        inputTextView.smartInsertDeleteType = .no
        inputTextView.spellCheckingType = .no
        inputTextView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 16, weight: .regular),
            maximumPointSize: 22
        )
        inputTextView.adjustsFontForContentSizeCategory = true
        inputTextView.layer.borderColor = UIColor.separator.cgColor
        inputTextView.layer.borderWidth = 1
        inputTextView.layer.cornerRadius = 6
        inputTextView.text = ""

        keyRow.axis = .horizontal
        keyRow.alignment = .fill
        keyRow.distribution = .fillEqually
        keyRow.spacing = 2
        for entry in terminalAccessoryEntries {
            let button = makeKeyButton(entry)
            keyRow.addArrangedSubview(button)
            if entry.tag == 1 { controlButton = button }
        }

        var dismissConfiguration = UIButton.Configuration.plain()
        dismissConfiguration.image = UIImage(systemName: "keyboard.chevron.compact.down")
        dismissConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .body
        )
        keyboardDismissButton.configuration = dismissConfiguration
        keyboardDismissButton.addTarget(
            self,
            action: #selector(dismissKeyboard),
            for: .touchUpInside
        )

        for subview in [inputTextView, keyRow, keyboardDismissButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            inputTextView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            inputTextView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            inputTextView.topAnchor.constraint(equalTo: topAnchor),
            inputTextView.heightAnchor.constraint(equalToConstant: 44),

            keyRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            keyRow.trailingAnchor.constraint(equalTo: keyboardDismissButton.leadingAnchor),
            keyRow.topAnchor.constraint(equalTo: inputTextView.bottomAnchor),
            keyRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            keyRow.heightAnchor.constraint(equalToConstant: 44),

            keyboardDismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            keyboardDismissButton.topAnchor.constraint(equalTo: keyRow.topAnchor),
            keyboardDismissButton.widthAnchor.constraint(equalToConstant: 44),
            keyboardDismissButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func makeKeyButton(_ entry: TerminalAccessoryEntry) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 0
        )
        configuration.title = entry.systemImage == nil ? entry.title : nil
        configuration.titleLineBreakMode = .byClipping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        configuration.image = entry.systemImage.flatMap(UIImage.init(systemName:))
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .body
        )
        let button = UIButton(configuration: configuration)
        button.tag = entry.tag
        button.titleLabel?.numberOfLines = 1
        button.addTarget(self, action: #selector(accessoryTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func accessoryTapped(_ sender: UIButton) {
        guard let key = MobileAccessoryKey(tag: sender.tag) else { return }
        let isControlLatched = onAccessoryKey?(key) ?? false
        if key == .control, let controlButton {
            controlButton.isSelected = isControlLatched
            var configuration = controlButton.configuration
            configuration?.baseForegroundColor = isControlLatched ? .systemOrange : tintColor
            controlButton.configuration = configuration
        }
        focusInput()
    }

    @objc private func dismissKeyboard() {
        onDismissKeyboard?()
    }
}

/// Separates an explicit paste gesture from ordinary committed keyboard text.
@MainActor
private final class TerminalInputTextView: UITextView {
    var onPaste: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { onPaste?(text) }
    }
}

/// Describes one terminal key without coupling its presentation to input mapping.
private struct TerminalAccessoryEntry {
    let title: String
    let systemImage: String?
    let tag: Int
}

private let terminalAccessoryEntries = [
    TerminalAccessoryEntry(
        title: "Esc", systemImage: nil, tag: 0
    ),
    TerminalAccessoryEntry(
        title: "Ctrl", systemImage: nil, tag: 1
    ),
    TerminalAccessoryEntry(
        title: "Tab", systemImage: nil, tag: 2
    ),
    TerminalAccessoryEntry(
        title: "Up", systemImage: "arrow.up", tag: 3
    ),
    TerminalAccessoryEntry(
        title: "Down", systemImage: "arrow.down", tag: 4
    ),
    TerminalAccessoryEntry(
        title: "Left", systemImage: "arrow.left", tag: 5
    ),
    TerminalAccessoryEntry(
        title: "Right", systemImage: "arrow.right", tag: 6
    ),
    TerminalAccessoryEntry(
        title: "|", systemImage: nil, tag: 7
    ),
    TerminalAccessoryEntry(
        title: "~", systemImage: nil, tag: 8
    ),
    TerminalAccessoryEntry(
        title: "/", systemImage: nil, tag: 9
    ),
]

private extension MobileAccessoryKey {
    init?(tag: Int) {
        switch tag {
        case 0: self = .escape
        case 1: self = .control
        case 2: self = .tab
        case 3: self = .up
        case 4: self = .down
        case 5: self = .left
        case 6: self = .right
        case 7: self = .pipe
        case 8: self = .tilde
        case 9: self = .slash
        default: return nil
        }
    }
}
