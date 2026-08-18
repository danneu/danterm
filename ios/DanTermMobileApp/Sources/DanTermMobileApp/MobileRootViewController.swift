// Places the phone's views and turns every UIKit gesture into a session event.
//
// It decides nothing about the session. The connection, the pane list, the selection, the
// status, and the claim control all live in `MobileSessionModel`; this file sends events in
// and renders the projection that comes back.
import DanTermMobileKit
import DanTermProtocol
import UIKit

/// Keeps every UIKit state transition on the main actor while sessions block elsewhere.
@MainActor
final class MobileRootViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let session = MobileSessionController()
    private let connectionHeader = ConnectionHeaderView()
    private let paneTable = UITableView(frame: .zero, style: .plain)
    private let composer = TerminalComposerView()
    private let claimBar = UIStackView()
    private let claimButton = UIButton(type: .system)
    private let releaseButton = UIButton(type: .system)

    /// The rows the table is currently showing. It is the data source's own copy of the
    /// projection, reloaded when the projection moves -- not a second owner of the list.
    private var panes: [MobilePaneListItem] = []
    private var selectedPaneId: PaneId?

    private var terminalView: TerminalSurfaceView { session.surfaceView }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        session.didUpdate = { [weak self] projection in self?.render(projection) }
        session.start()
        // The fields are the draft's editor, so they are filled once from the launch and
        // left alone afterwards: a redraw arriving mid-edit must not rewrite what the user
        // is typing.
        let launched = session.projection
        connectionHeader.hostText = launched.draft.host
        connectionHeader.portText = launched.draft.port
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        session.surfaceDidLayout()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let modifiers = key.modifierFlags.mobileModifiers
            if let named = key.keyCode.mobileNamedKey {
                session.dispatch(.hardwareKeyPressed(named, modifiers))
                handled = true
            } else if modifiers.isEmpty == false,
                      let character = key.charactersIgnoringModifiers.lowercased().first
            {
                session.dispatch(.hardwareCharacterPressed(character, modifiers))
                handled = true
            }
        }
        if handled == false { super.pressesBegan(presses, with: event) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        panes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pane", for: indexPath)
        let pane = panes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = pane.paneTitle
        content.secondaryText = "\(pane.groupName) / \(pane.tabTitle)"
        cell.contentConfiguration = content
        cell.accessoryType = pane.paneId == selectedPaneId ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        session.dispatch(.paneSelected(panes[indexPath.row].paneId))
    }

    private func configureViews() {
        connectionHeader.onConnect = { [weak self] in
            guard let self else { return }
            session.dispatch(.connectRequested(MobileTargetDraft(
                host: connectionHeader.hostText,
                port: connectionHeader.portText
            )))
        }
        paneTable.dataSource = self
        paneTable.delegate = self
        paneTable.rowHeight = UITableView.automaticDimension
        paneTable.estimatedRowHeight = 52
        paneTable.register(UITableViewCell.self, forCellReuseIdentifier: "pane")
        composer.onText = { [weak self] text in self?.session.dispatch(.textEntered(text)) }
        composer.onPaste = { [weak self] text in self?.session.dispatch(.pasted(text)) }
        composer.onAccessoryKey = { [weak self] key in
            guard let self else { return false }
            session.dispatch(.accessoryKeyPressed(key))
            return session.projection.isControlLatched
        }
        composer.onDismissKeyboard = { [weak self] in self?.view.endEditing(true) }
        configureGeometryButton(claimButton, title: "Claim", action: #selector(claimTapped))
        configureGeometryButton(releaseButton, title: "Release", action: #selector(releaseTapped))
        claimBar.axis = .horizontal
        claimBar.alignment = .center
        claimBar.distribution = .fillEqually
        claimBar.spacing = 8
        claimBar.isLayoutMarginsRelativeArrangement = true
        claimBar.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 4,
            leading: 8,
            bottom: 4,
            trailing: 8
        )
        claimBar.addArrangedSubview(claimButton)
        claimBar.addArrangedSubview(releaseButton)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        terminalView.addGestureRecognizer(scroll)
        for subview in [connectionHeader, paneTable, terminalView, claimBar, composer]
        {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        configureConstraints()
    }

    /// Gives both geometry buttons the one appearance, so the pair reads as two forms of
    /// the same control rather than two unrelated actions.
    private func configureGeometryButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureConstraints() {
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        let preferredTableHeight = paneTable.heightAnchor.constraint(
            equalTo: view.heightAnchor,
            multiplier: 0.2
        )
        preferredTableHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            connectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectionHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            paneTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneTable.topAnchor.constraint(equalTo: connectionHeader.bottomAnchor, constant: 4),
            paneTable.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            paneTable.heightAnchor.constraint(lessThanOrEqualToConstant: 150),
            preferredTableHeight,

            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: paneTable.bottomAnchor),
            terminalView.bottomAnchor.constraint(equalTo: claimBar.topAnchor),

            // The bar sits beside the terminal rather than over it, so no cell is ever
            // drawn underneath it, claimed or not.
            claimBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            claimBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            claimBar.bottomAnchor.constraint(equalTo: composer.topAnchor),
            claimBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    /// Renders every control from the projection. Nothing here decides anything: each
    /// control is whatever the model says it is at this moment.
    private func render(_ projection: MobileSessionProjection) {
        connectionHeader.showStatus(projection.status.text, color: projection.status.severity.color)
        connectionHeader.showDraftProblem(projection.draftProblem?.label)
        if panes != projection.panes || selectedPaneId != projection.selectedPaneId {
            panes = projection.panes
            selectedPaneId = projection.selectedPaneId
            paneTable.reloadData()
        }
        // Only the buttons hide. The bar keeps its layout space either way, so the
        // terminal's extent -- and with it the grid a claim would name -- does not move
        // when an action appears or goes away.
        //
        // Written only on a change: a layout pass feeds this, and the stack view lays out
        // again whenever an arranged subview's hidden flag is set, so an unconditional
        // write would drive a layout loop.
        setOffered(claimButton, projection.claim.claim != nil)
        setOffered(releaseButton, projection.claim.release != nil)
    }

    private func setOffered(_ button: UIButton, _ offered: Bool) {
        guard button.isHidden == offered else { return }
        button.isHidden = offered == false
    }

    @objc private func claimTapped() {
        session.dispatch(.claimRequested)
    }

    @objc private func releaseTapped() {
        session.dispatch(.releaseRequested)
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let direction: InputWheelDirection =
            recognizer.translation(in: terminalView).y > 0 ? .up : .down
        session.dispatch(.scrolled(direction))
    }
}

private extension MobileStatusSeverity {
    /// The one UIKit decision the composed status leaves to the shell.
    var color: UIColor {
        switch self {
        case .normal: .secondaryLabel
        case .degraded: .systemOrange
        case .failed: .systemRed
        }
    }
}

private extension UIKeyModifierFlags {
    var mobileModifiers: KeyMods {
        var result: KeyMods = []
        if contains(.control) { result.insert(.ctrl) }
        if contains(.alternate) { result.insert(.alt) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}

private extension UIKeyboardHIDUsage {
    var mobileNamedKey: NamedKey? {
        switch self {
        case .keyboardReturnOrEnter: .enter
        case .keyboardTab: .tab
        case .keyboardDeleteOrBackspace: .bspace
        case .keyboardEscape: .escape
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        case .keyboardHome: .home
        case .keyboardEnd: .end
        case .keyboardPageUp: .pgUp
        case .keyboardPageDown: .pgDn
        case .keyboardInsert: .insert
        case .keyboardDeleteForward: .delete
        default: nil
        }
    }
}
