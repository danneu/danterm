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
final class MobileRootViewController: UIViewController {
    private let session = MobileSessionController()
    private let statusPill = ConnectionStatusPillView()
    private let bottomBar = TerminalBottomBarView()

    /// Whether the launch has already been given its answer about the connect sheet. It
    /// is presentation choreography, not a session fact: whether a sheet is *wanted* is
    /// read from the model each time.
    private var hasAnsweredLaunch = false

    private var terminalView: TerminalSurfaceView { session.surfaceView }
    private var terminalInput: TerminalInputView { session.inputView }

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The terminal's bottom sits at the bar's rest position, so how far the bar's
        // top has risen above it is exactly how much of the drawn content the keyboard
        // obscures. The surface's placement value clamps and quantizes the measurement;
        // this is the only keyboard fact that ever leaves this controller.
        terminalView.obscuredBottomHeight = terminalView.frame.maxY - bottomBar.frame.minY
        // Focus changes drive the keyboard layout guide, which drives this pass, so this
        // is where the button learns that a tap on the grid raised the keyboard.
        bottomBar.setKeyboardShown(terminalInput.isFirstResponder)
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

    private func configureViews() {
        statusPill.addTarget(self, action: #selector(statusPillTapped), for: .touchUpInside)
        bottomBar.onPaneList = { [weak self] in self?.presentPaneSheet() }
        bottomBar.onAccessoryKey = { [weak self] key in
            guard let self else { return }
            // Read before the dispatch, so what is restored is the focus the tap found
            // rather than anything handling the key may have changed.
            let hadFocus = terminalInput.isFirstResponder
            session.dispatch(.accessoryKeyPressed(key))
            // The key was aimed at the terminal, so the terminal keeps the focus a tap on
            // the bar would otherwise have taken -- but only when it already held it. A
            // key pressed with the keyboard down must not summon the keyboard: it is
            // raised by the keyboard button or by a tap on the grid, never as a side
            // effect of typing one of these keys.
            if hadFocus { terminalInput.becomeFirstResponder() }
        }
        bottomBar.onToggleKeyboard = { [weak self] in
            guard let self else { return }
            if terminalInput.isFirstResponder {
                terminalInput.resignFirstResponder()
            } else {
                terminalInput.becomeFirstResponder()
            }
            bottomBar.setKeyboardShown(terminalInput.isFirstResponder)
        }
        bottomBar.menuItems = { [weak self] in self?.sessionMenuItems() ?? [] }
        // The input view covers the terminal so a tap anywhere on the grid raises the
        // keyboard, and the pill is added after both because it floats over them.
        // Everything else sits beside the terminal and takes its own space.
        for subview in [terminalView, terminalInput, bottomBar, statusPill] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The chrome sits under the input view, which must keep every touch: its own pan
        // recognizer is moved onto that view instead, so a swipe scrolls while tap-to-focus
        // and long-press stay where they were. It sizes itself to the drawn grid rather
        // than to the terminal's extent, so it is placed by frame and takes no constraint.
        let scrollChrome = session.scrollChrome
        view.insertSubview(scrollChrome, aboveSubview: terminalView)
        terminalInput.addGestureRecognizer(scrollChrome.panGestureRecognizer)
        configureConstraints()
    }

    /// Names the session actions the model offers right now. It is asked when the menu
    /// opens, and each item carries an event rather than the request the facts imply at
    /// that instant -- the model builds the request when it handles the event.
    private func sessionMenuItems() -> [TerminalBarMenuItem] {
        let projection = session.projection
        var items: [TerminalBarMenuItem] = []
        if projection.canCreatePane {
            items.append(TerminalBarMenuItem(
                title: "New pane",
                systemImage: "rectangle.split.2x1"
            ) { [weak self] in self?.session.dispatch(.newPaneRequested) })
        }
        let claim = projection.claim
        if claim.claim != nil {
            items.append(TerminalBarMenuItem(
                title: "Claim",
                systemImage: "arrow.down.right.and.arrow.up.left"
            ) { [weak self] in self?.session.dispatch(.claimRequested) })
        }
        if claim.release != nil {
            items.append(TerminalBarMenuItem(
                title: "Release",
                systemImage: "arrow.up.left.and.arrow.down.right"
            ) { [weak self] in self?.session.dispatch(.releaseRequested) })
        }
        return items
    }

    private func configureConstraints() {
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            // Full bleed: the terminal owns the whole width and everything from the
            // physical top of the window down to the bar's rest position. Nothing is
            // allowed to take vertical space above it -- the pill floats over it instead.
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            // The bar's rest position, not the bar itself: the keyboard is a presentation
            // offset, never a geometry input, so the terminal's bounds -- and with them
            // the grid a claim names and the pixels the frame stores hold -- must not
            // move when the bar rides the keyboard up. The rise is measured in
            // `viewDidLayoutSubviews` and handed to the surface as one scalar.
            terminalView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -TerminalBottomBarView.height
            ),

            // The input view is the terminal's own surface as far as touches go, so it
            // covers exactly what the terminal covers.
            terminalInput.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            terminalInput.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            terminalInput.topAnchor.constraint(equalTo: terminalView.topAnchor),
            terminalInput.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),

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

            // The bar sits beside the terminal rather than over it, so no cell is ever
            // drawn underneath it, claimed or not. Its height is a constant, so the
            // terminal's extent does not move when the overflow menu gains or loses an
            // action.
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: TerminalBottomBarView.height),
        ])
    }

    /// Renders every control from the projection. Nothing here decides anything: each
    /// control is whatever the model says it is at this moment.
    private func render(_ projection: MobileSessionProjection) {
        let color = projection.status.severity.color
        // The pill composes the status line with the prepared location it is about. The
        // two facts stay separately owned; only this call puts them beside each other.
        statusPill.show(
            status: projection.status.text,
            color: color,
            breadcrumb: projection.breadcrumb?.text
        )
        // A draft problem is shown beside the fields it is about, which exist only while
        // the sheet is up. The status repeats there so the sheet can be read on its own.
        if let sheet = presentedViewController as? ConnectSheetViewController {
            sheet.showStatus(projection.status.text, color: color)
            sheet.showDraftProblem(projection.draftProblem?.label)
        }
        // The list is a model fact, so a pane the Mac opens or closes reaches the sheet
        // while it is up rather than waiting for the user to close and reopen it.
        if let sheet = presentedViewController as? PaneSheetViewController {
            sheet.show(outline: projection.outline, selected: projection.selectedPaneId)
        }
        // Only whether the menu opens follows the projection. The bar's height is fixed,
        // so the terminal's extent -- and with it the grid a claim would name -- does not
        // move when an action appears or goes away. What the menu contains is asked for
        // again when it opens.
        bottomBar.setMenuOffered(
            projection.canCreatePane
                || projection.claim.claim != nil
                || projection.claim.release != nil
        )
        // The latch is a session fact like any other: the highlight follows the
        // projection, so an input that spent the latch unlights the key with no Ctrl tap.
        bottomBar.setLatchedModifiers(projection.latchedModifiers)
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

    /// Opens the pane list. It dismisses itself on a pick, which is what keeps the terminal
    /// the screen the user lives on.
    ///
    /// Medium detent only, as the connect sheet is: a large sheet would rise over the pill,
    /// and the connection status has to stay readable while a sheet is up. A list too long
    /// for the detent scrolls inside it.
    private func presentPaneSheet() {
        guard presentedViewController == nil else { return }
        let projection = session.projection
        let sheet = PaneSheetViewController(
            outline: projection.outline,
            selected: projection.selectedPaneId
        )
        sheet.onSelect = { [weak self] pane in self?.session.dispatch(.paneSelected(pane)) }
        sheet.sheetPresentationController?.detents = [.medium()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        present(sheet, animated: true)
        render(session.projection)
    }

    @objc private func statusPillTapped() {
        presentConnectSheet()
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
