// Owns terminal text entry: the field that raises the keyboard and forwards what is typed.
//
// The key row and keyboard dismissal moved to `TerminalBottomBarView`, which is the row of
// controls the terminal screen keeps. This view is the last piece of the old composer and
// goes away when the terminal itself becomes the text-input target.
import UIKit

/// Keeps a keyboard-raising text target on screen while the terminal cannot be one itself.
@MainActor
final class TerminalComposerView: UIView, UITextViewDelegate {
    var onText: ((String) -> Void)?
    var onPaste: ((String) -> Void)?

    private let inputTextView = TerminalInputTextView()

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
        inputTextView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputTextView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            inputTextView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            inputTextView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            inputTextView.topAnchor.constraint(equalTo: topAnchor),
            inputTextView.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputTextView.heightAnchor.constraint(equalToConstant: 44),
        ])
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
