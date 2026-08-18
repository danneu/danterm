// The floating status the terminal screen spends no vertical space on.
//
// It reports what the connection is doing and which pane is on screen, and it is the
// gesture that opens the connect sheet. It holds no fact of its own: every call to
// `show` states the whole thing, so there is nothing here for a stale value to survive in.
import UIKit

/// Overlays the terminal's top safe area with the status line and the pane it describes.
///
/// A `UIControl` rather than a view with a tap recognizer, so the tap that opens the
/// connect sheet is the control's own action and cannot compete with the terminal's
/// gestures underneath it.
@MainActor
final class ConnectionStatusPillView: UIControl {
    private let background = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemThinMaterialDark)
    )
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// States the whole pill: the composed status line, the color the shell chose for its
    /// severity, and the pane the line is about, or nothing when no pane is selected.
    func show(status: String, color: UIColor, paneTitle: String?) {
        statusLabel.text = status
        statusLabel.textColor = color
        titleLabel.text = paneTitle
        // Written only on a change: hiding an arranged subview lays the stack out again,
        // and this runs from a redraw a layout pass can produce.
        let hidesTitle = paneTitle == nil
        if titleLabel.isHidden != hidesTitle { titleLabel.isHidden = hidesTitle }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func configureViews() {
        layer.masksToBounds = true
        // The pill floats over black terminal pixels whatever the system appearance is,
        // so its semantic colors are resolved for a dark background rather than the
        // device's setting.
        overrideUserInterfaceStyle = .dark

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(statusLabel)
        // The pill is one control: a tap anywhere in it opens the sheet, and nothing
        // inside it takes the touch first.
        stack.isUserInteractionEnabled = false
        background.isUserInteractionEnabled = false

        for subview in [background, stack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }
}
