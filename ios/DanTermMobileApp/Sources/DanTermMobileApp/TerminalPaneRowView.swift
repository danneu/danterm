// The fixed row between the terminal and the bottom bar: which pane is on screen, and how
// the connection is doing.
//
// It is the terminal screen's only way into the connect sheet and the only way into the
// pane picker, so neither affordance has a second entry point to keep in step with it. Its
// height is a constant, so the terminal above it never moves in response to anything the
// row shows.
//
// What does not belong here: any session fact. The row remembers nothing between calls --
// `show` states the whole row -- and it reports gestures rather than acting on them.
import DanTermMobileKit
import UIKit

/// Places the pane row's two controls and reports every tap on it as a gesture.
@MainActor
final class TerminalPaneRowView: UIView {
    /// Reports the connection dot. Whether the sheet may open is the controller's fact.
    var onConnection: (() -> Void)?
    /// Reports the pane name. The row does not know what the picker will contain.
    var onPaneList: (() -> Void)?

    /// The row's fixed height, which is also the dot's tap target. The row is sized to a
    /// comfortable target rather than to its small artwork, so the target needs no
    /// hit-testing that reaches outside the row and steals taps from the grid above it.
    static let height: CGFloat = 44

    private let connectionButton = UIButton(type: .system)
    private let paneButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Opaque, because a partial keyboard lift leaves live rows behind this strip;
        // no cell may show through the row.
        backgroundColor = .black
        configureViews()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// States the whole row: the color the shell chose for the connection's severity, and
    /// the selected pane's prepared name, or nothing when no pane is on screen.
    func show(connectionColor: UIColor, paneTitle: MobileDisplayText?) {
        // Both writes are guarded, because this runs from a redraw a layout pass can
        // produce and a button's configuration schedules its own layout when it is set.
        var connection = connectionButton.configuration
        if connection?.baseForegroundColor != connectionColor {
            connection?.baseForegroundColor = connectionColor
            connectionButton.configuration = connection
        }
        var pane = paneButton.configuration
        if pane?.title != paneTitle?.text {
            pane?.title = paneTitle?.text
            paneButton.configuration = pane
            paneButton.accessibilityLabel = paneTitle.map { "Pane: \($0.text)" } ?? "Panes"
        }
    }

    private func configureViews() {
        var connection = UIButton.Configuration.plain()
        connection.image = UIImage(systemName: "circle.fill")
        connection.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10
        )
        connection.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 0
        )
        connectionButton.configuration = connection
        connectionButton.accessibilityLabel = "Connection"
        connectionButton.addTarget(
            self,
            action: #selector(connectionTapped),
            for: .touchUpInside
        )

        var pane = UIButton.Configuration.plain()
        pane.image = UIImage(systemName: "chevron.up.chevron.down")
        pane.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9)
        pane.imagePlacement = .trailing
        pane.imagePadding = 5
        pane.titleLineBreakMode = .byTruncatingTail
        pane.baseForegroundColor = .label
        pane.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 0
        )
        pane.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .subheadline)
            return outgoing
        }
        paneButton.configuration = pane
        // The name reads from the leading edge, so a title too long for the phone
        // truncates at its tail rather than sliding out of both sides of a centered row.
        paneButton.contentHorizontalAlignment = .leading
        paneButton.addTarget(self, action: #selector(paneListTapped), for: .touchUpInside)

        for subview in [connectionButton, paneButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            connectionButton.leadingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.leadingAnchor
            ),
            connectionButton.topAnchor.constraint(equalTo: topAnchor),
            connectionButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            connectionButton.widthAnchor.constraint(equalToConstant: Self.height),

            paneButton.leadingAnchor.constraint(equalTo: connectionButton.trailingAnchor),
            paneButton.trailingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.trailingAnchor,
                constant: -12
            ),
            paneButton.topAnchor.constraint(equalTo: topAnchor),
            paneButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func connectionTapped() {
        onConnection?()
    }

    @objc private func paneListTapped() {
        onPaneList?()
    }
}
