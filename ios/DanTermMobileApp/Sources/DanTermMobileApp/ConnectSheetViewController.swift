// The transient form that names the Mac to connect to.
//
// It replaces the permanent connection header: the target fields, the Go button, and the
// problem with what they hold are things the user needs while naming a server and never
// afterwards, so they live in a sheet the terminal screen gives no space to.
//
// It decides nothing. It reports the Go gesture with the text it holds and paints what it
// is told; the session model decides whether that text names a server.
import DanTermMobileKit
import UIKit

/// Presents the target fields for as long as the user is naming a server.
///
/// The fields are the draft's editor while this is on screen, which is why the sheet is
/// created for one presentation and seeded once: a redraw arriving mid-edit paints the
/// status and the problem, never the fields.
@MainActor
final class ConnectSheetViewController: UIViewController {
    /// Reports the Go gesture with the text the fields hold at that moment.
    var onConnect: ((MobileTargetDraft) -> Void)?

    private let hostField = UITextField()
    private let portField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let draftProblemLabel = UILabel()

    /// Seeds the fields from the draft the model holds. Called once, when the sheet is
    /// built for a presentation.
    init(draft: MobileTargetDraft) {
        super.init(nibName: nil, bundle: nil)
        hostField.text = draft.host
        portField.text = draft.port
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The text the fields hold right now, which is what a Go gesture is about.
    var draft: MobileTargetDraft {
        MobileTargetDraft(host: hostField.text, port: portField.text)
    }

    func showStatus(_ text: String, color: UIColor) {
        // Both writes are guarded, because a redraw arrives for every keystroke while the
        // sheet is up and states the whole status again. Each guard reads the label, which
        // holds the only value there is, so text and color are compared and written apart.
        if statusLabel.text != text { statusLabel.text = text }
        if statusLabel.textColor != color { statusLabel.textColor = color }
    }

    /// Reports a problem with the target fields, or clears it with `nil`. It has its own
    /// label beside the fields, so it can never be read as part of the connection status.
    func showDraftProblem(_ text: String?) {
        // Guarded for the same reason as `showStatus`: every keystroke restates the same
        // problem, or the same absence of one.
        if draftProblemLabel.text != text { draftProblemLabel.text = text }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The sheet slides up over the terminal's black, and a presented controller does
        // not inherit the presenter's override, so it states the same dark appearance
        // itself rather than flashing a white form over the screen behind it.
        overrideUserInterfaceStyle = .dark
        // An explicit near-black rather than a system background color: the sheet rises
        // over the terminal's own black, so it needs to be dark enough to belong to the
        // same screen and light enough to read as a surface in front of it.
        view.backgroundColor = UIColor(white: 0.11, alpha: 1)
        configureViews()
        configureConstraints()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The sheet exists to be typed into, so it opens with the field a host is missing
        // from already accepting keys.
        if hostField.text?.isEmpty != false { hostField.becomeFirstResponder() }
    }

    private func configureViews() {
        hostField.borderStyle = .roundedRect
        hostField.placeholder = "Mac tailnet host"
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.spellCheckingType = .no
        hostField.font = .preferredFont(forTextStyle: .body)
        hostField.adjustsFontForContentSizeCategory = true
        hostField.returnKeyType = .go
        hostField.addTarget(self, action: #selector(connectTapped), for: .primaryActionTriggered)

        portField.borderStyle = .roundedRect
        portField.placeholder = "7420"
        portField.keyboardType = .numberPad
        portField.adjustsFontSizeToFitWidth = true
        portField.minimumFontSize = 12
        portField.font = .preferredFont(forTextStyle: .body)
        portField.adjustsFontForContentSizeCategory = true

        var connectConfiguration = UIButton.Configuration.filled()
        connectConfiguration.title = "Go"
        connectConfiguration.cornerStyle = .capsule
        connectButton.configuration = connectConfiguration
        connectButton.titleLabel?.adjustsFontForContentSizeCategory = true
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)

        draftProblemLabel.font = .preferredFont(forTextStyle: .caption1)
        draftProblemLabel.adjustsFontForContentSizeCategory = true
        draftProblemLabel.textColor = .systemRed
        draftProblemLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        for subview in [hostField, portField, connectButton, draftProblemLabel, statusLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            hostField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            hostField.topAnchor.constraint(equalTo: margins.topAnchor, constant: 24),
            hostField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            portField.leadingAnchor.constraint(equalTo: hostField.trailingAnchor, constant: 8),
            portField.topAnchor.constraint(equalTo: hostField.topAnchor),
            portField.widthAnchor.constraint(equalToConstant: 76),
            portField.heightAnchor.constraint(equalTo: hostField.heightAnchor),

            connectButton.leadingAnchor.constraint(equalTo: portField.trailingAnchor, constant: 8),
            connectButton.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            connectButton.topAnchor.constraint(equalTo: hostField.topAnchor),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            connectButton.heightAnchor.constraint(equalTo: hostField.heightAnchor),

            // Directly under the fields it describes, and above the connection status it
            // must never join. An empty label has no height, so it costs nothing.
            draftProblemLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            draftProblemLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            draftProblemLabel.topAnchor.constraint(equalTo: hostField.bottomAnchor, constant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            statusLabel.topAnchor.constraint(
                equalTo: draftProblemLabel.bottomAnchor,
                constant: 8
            ),
        ])
    }

    @objc private func connectTapped() {
        onConnect?(draft)
    }
}
