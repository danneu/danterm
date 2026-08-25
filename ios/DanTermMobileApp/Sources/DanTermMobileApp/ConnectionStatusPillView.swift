// The floating words for a connection that is not healthy, and nothing else.
//
// It is on screen only while the status has something to say, so the terminal gets its top
// back in every state the user does not need to read about. It holds no fact of its own:
// every call to `show` states the whole thing, so there is nothing here for a stale value
// to survive in.
//
// What does not belong here: any control. The pane row owns the way into the connect sheet
// and the way into the pane picker, so the pill reports and takes no touch at all.
import UIKit

/// Floats the composed status line over the terminal's top safe area while it is shown.
///
/// A plain view rather than a control: touches pass through it to the terminal underneath,
/// so a pill that appears under the user's finger cannot swallow a tap meant for the grid.
@MainActor
final class ConnectionStatusPillView: UIView {
    private let background = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemThinMaterialDark)
    )
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

    /// States the whole pill: the composed status line and the color the shell chose for
    /// its severity.
    func show(status: String, color: UIColor) {
        statusLabel.text = status
        statusLabel.textColor = color
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func configureViews() {
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        // The pill floats over black terminal pixels whatever the system appearance is,
        // so its semantic colors are resolved for a dark background rather than the
        // device's setting.
        overrideUserInterfaceStyle = .dark

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        for subview in [background, statusLabel] {
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

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }
}
