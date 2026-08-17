// Owns the server target controls and connection status layout.
import UIKit

/// Keeps connection chrome and its adaptive layout out of the session-owning controller.
@MainActor
final class ConnectionHeaderView: UIView {
    var onConnect: (() -> Void)?

    private let hostField = UITextField()
    private let portField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let draftProblemLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var hostText: String? {
        get { hostField.text }
        set { hostField.text = newValue }
    }

    var portText: String? {
        get { portField.text }
        set { portField.text = newValue }
    }

    func showStatus(_ text: String, color: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
    }

    /// Reports a problem with the target fields, or clears it with `nil`. It has its own
    /// label so it can never be read as part of the connection status beside it.
    func showDraftProblem(_ text: String?) {
        draftProblemLabel.text = text
    }

    private func configureViews() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8)

        hostField.borderStyle = .roundedRect
        hostField.placeholder = "Mac tailnet host"
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.spellCheckingType = .no
        hostField.font = .preferredFont(forTextStyle: .body)
        hostField.adjustsFontForContentSizeCategory = true

        portField.borderStyle = .roundedRect
        portField.placeholder = "7420"
        portField.keyboardType = .numberPad
        portField.adjustsFontSizeToFitWidth = true
        portField.minimumFontSize = 12
        portField.font = .preferredFont(forTextStyle: .body)
        portField.adjustsFontForContentSizeCategory = true

        var connectConfiguration = UIButton.Configuration.plain()
        connectConfiguration.title = "Go"
        connectButton.configuration = connectConfiguration
        connectButton.titleLabel?.adjustsFontForContentSizeCategory = true
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        draftProblemLabel.font = .preferredFont(forTextStyle: .caption1)
        draftProblemLabel.adjustsFontForContentSizeCategory = true
        draftProblemLabel.textColor = .systemRed
        draftProblemLabel.numberOfLines = 0

        for subview in [hostField, portField, connectButton, draftProblemLabel, statusLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    private func configureConstraints() {
        let margins = layoutMarginsGuide
        NSLayoutConstraint.activate([
            hostField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            hostField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            hostField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            portField.leadingAnchor.constraint(equalTo: hostField.trailingAnchor, constant: 8),
            portField.topAnchor.constraint(equalTo: hostField.topAnchor),
            portField.widthAnchor.constraint(equalToConstant: 68),
            portField.heightAnchor.constraint(equalTo: hostField.heightAnchor),

            connectButton.leadingAnchor.constraint(equalTo: portField.trailingAnchor, constant: 4),
            connectButton.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            connectButton.topAnchor.constraint(equalTo: hostField.topAnchor),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            connectButton.heightAnchor.constraint(equalTo: hostField.heightAnchor),

            // Directly under the fields it describes, and above the connection status line
            // it must never join. An empty label has no height, so it costs nothing.
            draftProblemLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            draftProblemLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            draftProblemLabel.topAnchor.constraint(equalTo: hostField.bottomAnchor, constant: 4),

            statusLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: draftProblemLabel.bottomAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func connectTapped() {
        onConnect?()
    }
}
