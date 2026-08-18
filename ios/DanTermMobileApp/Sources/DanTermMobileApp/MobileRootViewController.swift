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
    private let statusPill = ConnectionStatusPillView()
    private let paneTable = UITableView(frame: .zero, style: .plain)
    private let composer = TerminalComposerView()
    private let claimBar = UIStackView()
    private let claimButton = UIButton(type: .system)
    private let releaseButton = UIButton(type: .system)

    /// The rows the table is currently showing. It is the data source's own copy of the
    /// projection, reloaded when the projection moves -- not a second owner of the list.
    private var panes: [MobilePaneListItem] = []
    private var selectedPaneId: PaneId?
    /// Whether the launch has already been given its answer about the connect sheet. It
    /// is presentation choreography, not a session fact: whether a sheet is *wanted* is
    /// read from the model each time.
    private var hasAnsweredLaunch = false

    private var terminalView: TerminalSurfaceView { session.surfaceView }

    /// The terminal runs edge to edge in black, so the status bar's own content is drawn
    /// light over it whatever the device's appearance setting is.
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The terminal reaches the physical edges, so the screen behind it is the
        // terminal's own black and every control on it resolves its colors for a dark
        // background.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configureViews()
        session.didUpdate = { [weak self] projection in self?.render(projection) }
        session.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard hasAnsweredLaunch == false else { return }
        hasAnsweredLaunch = true
        // A launch that named a server is already connecting, and a sheet over it would
        // stall the smoke run behind a form nobody asked for. The sheet is offered only
        // when the launch could not name one -- no host at all, or a draft the model
        // refused -- because the problem it reported has nowhere else to be read.
        let launched = session.projection
        guard launched.draft.host == nil || launched.draftProblem != nil else { return }
        presentConnectSheet()
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
        statusPill.addTarget(self, action: #selector(statusPillTapped), for: .touchUpInside)
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
        // The pill is added after the terminal because it floats over it. Everything else
        // sits beside the terminal and takes its own space.
        for subview in [terminalView, paneTable, claimBar, composer, statusPill] {
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
            // Full bleed: the terminal owns the whole width and everything from the
            // physical top of the window down to the controls at the bottom. Nothing is
            // allowed to take vertical space above it -- the pill floats over it instead.
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: paneTable.topAnchor),

            statusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusPill.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 4
            ),
            statusPill.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 12
            ),
            statusPill.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -12
            ),

            // The table sits below the terminal until the pane sheet replaces it, so the
            // terminal keeps the top of the window either way.
            paneTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneTable.bottomAnchor.constraint(equalTo: claimBar.topAnchor),
            paneTable.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            paneTable.heightAnchor.constraint(lessThanOrEqualToConstant: 150),
            preferredTableHeight,

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
        let color = projection.status.severity.color
        // The pill composes the status line with the pane it is about. The two facts stay
        // separately owned; only this line puts them beside each other.
        statusPill.show(
            status: projection.status.text,
            color: color,
            paneTitle: projection.panes.first { $0.paneId == projection.selectedPaneId }?.paneTitle
        )
        // A draft problem is shown beside the fields it is about, which exist only while
        // the sheet is up. The status repeats there so the sheet can be read on its own.
        if let sheet = presentedViewController as? ConnectSheetViewController {
            sheet.showStatus(projection.status.text, color: color)
            sheet.showDraftProblem(projection.draftProblem?.label)
        }
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

    /// Opens the form that names a server. The sheet is built for this one presentation
    /// and seeded from the model's draft, so the fields are the draft's editor only while
    /// they are on screen and no redraw can rewrite what the user is typing.
    ///
    /// It is a medium-detent sheet so the pill above it stays visible: the status has to
    /// be readable while the user is deciding what to type into the form.
    private func presentConnectSheet() {
        guard presentedViewController == nil else { return }
        let sheet = ConnectSheetViewController(draft: session.projection.draft)
        sheet.onConnect = { [weak self, weak sheet] draft in
            guard let self, let sheet else { return }
            session.dispatch(.connectRequested(draft))
            // The model decides whether that text named a server. When it did, the form
            // has nothing left to say and gets out of the terminal's way; when it did not,
            // the sheet stays up holding the problem it was just given.
            guard session.projection.draftProblem == nil else { return }
            sheet.dismiss(animated: true)
        }
        sheet.sheetPresentationController?.detents = [.medium()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        present(sheet, animated: true)
        render(session.projection)
    }

    @objc private func statusPillTapped() {
        presentConnectSheet()
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
