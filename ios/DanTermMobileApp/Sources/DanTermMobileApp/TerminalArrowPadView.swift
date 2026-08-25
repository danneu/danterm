// The floating 2x2 arrow pad the bottom bar's toggle reveals over the terminal.
//
// It exists because four arrows in the bottom row were the hardest keys on the phone to
// hit and took a permanent share of the row's width from every other key. Here they get
// a full touch target each, and the user can park them away from whatever the pane is
// drawing underneath.
//
// What does not belong here: where the pad sits. This view reports its drag and its four
// keys; the region it lives in, and the pane whose preference that region resolves, are
// the placing controller's business.
import DanTermMobileKit
import UIKit

/// Draws the four directions as standard glass buttons and reports every gesture on them.
///
/// It is a sibling of the terminal's input view rather than a subview: that view carries
/// the scroll pan recognizer along with tap-to-focus and long-press, so a pad inside it
/// would hand its own drag and taps to all three.
@MainActor
final class TerminalArrowPadView: UIView {
    /// Reports one direction. It is the same accessory key the bottom row used to send,
    /// so the pad adds no input path of its own.
    var onArrowKey: ((MobileAccessoryKey) -> Void)?
    /// Reports the move gesture at every stage. The placing controller owns the geometry,
    /// so it is handed the recognizer rather than a position this view invented.
    var onDrag: ((UIPanGestureRecognizer) -> Void)?
    /// Reports an assistive-technology request to park the pad in one corner, which is
    /// the way to move it without performing the drag.
    var onMoveToCorner: ((MobileArrowPadCorner) -> Void)?

    /// One direction's touch target. Above the 44pt minimum Apple asks for, because this
    /// control exists precisely because the 44pt-wide row slots were too small.
    private static let buttonSide: CGFloat = 56
    private static let spacing: CGFloat = 6

    /// The pad's fixed size. The placing controller resolves a position against it, so it
    /// is a constant rather than a measurement taken mid-layout.
    static let size = CGSize(
        width: buttonSide * 2 + spacing,
        height: buttonSide * 2 + spacing
    )

    /// The row order the pad draws: the two vertical directions above the two horizontal
    /// ones, which keeps each pair on one line and reads as a fixed shape rather than as
    /// a compass the user has to find.
    private static let rows: [[TerminalArrowDirection]] = [[.up, .down], [.left, .right]]

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Chrome over live terminal rows: only the buttons themselves are drawn, so the
        // cells between and around them stay readable.
        backgroundColor = .clear
        configureViews()
        configureAccessibility()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureViews() {
        let columns = Self.rows.map { row -> UIStackView in
            let stack = UIStackView(arrangedSubviews: row.map(makeArrowButton))
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = Self.spacing
            return stack
        }
        let grid = UIStackView(arrangedSubviews: columns)
        grid.axis = .vertical
        grid.distribution = .fillEqually
        grid.spacing = Self.spacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeArrowButton(_ direction: TerminalArrowDirection) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: direction.systemImage)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .title3
        )
        let button = UIButton(configuration: configuration)
        // The action carries the direction the button was drawn for, so a button cannot
        // report a direction other than its own.
        button.addAction(
            UIAction { [weak self] _ in self?.onArrowKey?(direction.key) },
            for: .touchUpInside
        )
        // The glyph is the whole button, so the label is the only thing VoiceOver has to
        // say which direction this is.
        button.accessibilityLabel = direction.label
        return button
    }

    /// Gives assistive technology the four corners as named actions, because the touch
    /// drag that moves the pad is unavailable to it.
    private func configureAccessibility() {
        accessibilityLabel = "Arrow pad"
        accessibilityCustomActions = MobileArrowPadCorner.allCases.map { corner in
            UIAccessibilityCustomAction(name: corner.movementActionName) { [weak self] _ in
                self?.onMoveToCorner?(corner)
                return true
            }
        }
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        onDrag?(recognizer)
    }
}

/// The four directions the pad draws, and how each is drawn, spoken, and sent.
///
/// The pad is built from this rather than from `MobileAccessoryKey`, so a key that is not
/// a direction cannot reach a pad button at all. That is what the bottom row's appearance
/// type gets from having no `default`, stated here as a type instead of as a switch.
private enum TerminalArrowDirection {
    case up
    case down
    case left
    case right

    /// The accessory key this direction sends. It is the same case the bottom row used to
    /// send, so the pad adds no input path of its own.
    var key: MobileAccessoryKey {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }

    var systemImage: String {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }

    /// What VoiceOver reads for this button, which is all it has: the glyph is the whole
    /// button and carries no text.
    var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

private extension MobileArrowPadCorner {
    /// What VoiceOver reads for the action that parks the pad in this corner.
    var movementActionName: String {
        switch self {
        case .topLeading: "Move to top leading"
        case .topTrailing: "Move to top trailing"
        case .bottomLeading: "Move to bottom leading"
        case .bottomTrailing: "Move to bottom trailing"
        }
    }
}
