// Makes the terminal itself the text-input target: the transparent responder over the
// grid that raises the keyboard, takes what is typed, and offers the paste action.
//
// It replaces the composer field, which spent a permanent band of the screen being the
// only thing on the phone allowed to hold a keyboard. Sitting over the terminal means the
// terminal is what the user taps to type into, which is what a terminal on a phone should
// be.
//
// What does not belong here: any session fact. This view reports gestures and text; where
// they go, and whether there is a pane to send them to, is the session model's business.
import DanTermMobileKit
import UIKit

/// Owns terminal focus and turns keyboard activity into the three text gestures.
///
/// It adopts `UIKeyInput` rather than the full `UITextInput`, which is the same trade the
/// composer made: there is no client-side buffer for the system to compose into, so
/// marked text is defeated exactly as it was before. What it gains over the composer is
/// the backspace, which a text view that rejects every change cannot report.
@MainActor
final class TerminalInputView: UIView, UIKeyInput, @preconcurrency UIEditMenuInteractionDelegate {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPaste: ((String) -> Void)?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addInteraction(editMenu)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Drives the smoke run's probe through the same entry points a user's keyboard uses,
    /// which is the whole point of the probe: the app package has no test target, so this
    /// responder is proved by being driven rather than by being asserted on.
    func drive(_ steps: [MobileSmokeInputStep]) {
        for step in steps {
            switch step {
            case .insertText(let text):
                insertText(text)
            case .deleteBackward:
                deleteBackward()
            case .paste(let text):
                // Through the pasteboard and the responder action, so the probe exercises
                // the path a real paste takes rather than the callback behind it.
                UIPasteboard.general.string = text
                paste(nil)
            }
        }
    }

    // MARK: - UIKeyInput

    /// Always true, so the system offers a backspace even though this view shows no text
    /// of its own. The characters it would delete are on the Mac.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }

    // MARK: - Editing actions

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        onPaste?(text)
    }

    // UIEditMenuInteractionDelegate: called when the menu is about to be shown.
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }

    @objc private func tapped() {
        becomeFirstResponder()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // The menu's actions are the responder's own, so the menu is worth nothing until
        // this view holds the focus they are asked about.
        becomeFirstResponder()
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: recognizer.location(in: self)
        ))
    }
}
