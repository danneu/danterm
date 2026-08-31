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
    private let paneRow = TerminalPaneRowView()
    private let bottomBar = TerminalBottomBarView()
    private let arrowPad = TerminalArrowPadView()

    /// Each pane's arrow pad, as a pure value. Every rule about it -- the default, what a
    /// toggle or a dismissal means, and where a stored preference lands in the region the
    /// phone currently has -- is decided in `DanTermMobileKit` and only applied here.
    private var arrowPads = MobileArrowPadState()

    /// The pane a drag began on and where its pad started, held only while a finger is
    /// down. It is the drag itself, which is UIKit's alone until it ends: naming the pane
    /// here is what keeps a pane change mid-drag from moving the wrong pane's pad.
    private var arrowPadDrag: (pane: PaneId, leadingInset: CGFloat, topInset: CGFloat)?

    /// How far the pad stays clear of the region's edges, so a pad parked in a corner is
    /// still visibly floating over the terminal rather than welded to it.
    private static let arrowPadMargin: CGFloat = 12

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
        // stall the smoke run behind a form nobody asked for. Whether the session still
        // needs a target is the model's own answer, so no launch rule is stated here.
        guard session.projection.needsTarget else { return }
        presentConnectSheet()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The terminal's bottom sits at the resting top of the chrome that rides the
        // keyboard, so how far the topmost of it has risen above that is exactly how much
        // of the drawn content the keyboard obscures. The row is that topmost view, not
        // the bar. The surface's placement value clamps and quantizes the measurement;
        // this is the only keyboard fact that ever leaves this controller.
        terminalView.obscuredBottomHeight = terminalView.frame.maxY - paneRow.frame.minY
        // Focus changes drive the keyboard layout guide, which drives this pass, so this
        // is where the button learns that a tap on the grid raised the keyboard.
        bottomBar.setKeyboardShown(terminalInput.isFirstResponder)
        // The same pass is where the pad's stored preference meets the region the
        // keyboard and the orientation have just left, which is what makes rotation and a
        // keyboard lift a re-resolve rather than a write.
        layoutArrowPad()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A thin adapter over the kit's decision: it reads UIKit's facts and dispatches
        // what comes back. A press the decision declines is left entirely to
        // `super.pressesBegan`, which is the only road to UIKit's text-input system --
        // the road that turns Shift+A into `A` and Shift+2 into `@`.
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let hardwarePress = MobileHardwareKeyPress(
                hidUsage: key.keyCode.rawValue,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                modifiers: key.modifierFlags.mobileModifiers,
                isCommandHeld: key.modifierFlags.contains(.command)
            )
            guard let terminalKey = hardwarePress.terminalKey else { continue }
            session.dispatch(.hardwareKeyPressed(terminalKey, hardwarePress.modifiers))
            handled = true
        }
        if handled == false { super.pressesBegan(presses, with: event) }
    }

    private func configureViews() {
        paneRow.onConnection = { [weak self] in self?.presentConnectSheet() }
        paneRow.onPaneList = { [weak self] in self?.presentPaneSheet() }
        bottomBar.onAccessoryKey = { [weak self] key in self?.sendAccessoryKey(key) }
        bottomBar.onToggleArrowPad = { [weak self] in
            guard let self, let pane = session.selectedPaneId else { return }
            arrowPads.toggle(pane)
            showArrowPad()
        }
        arrowPad.onArrowKey = { [weak self] key in self?.sendAccessoryKey(key) }
        arrowPad.onDrag = { [weak self] recognizer in self?.dragArrowPad(recognizer) }
        arrowPad.onMoveToCorner = { [weak self] corner in
            guard let self, let pane = session.selectedPaneId else { return }
            arrowPads.move(pane, to: corner.position)
            showArrowPad()
        }
        // The one gesture that dismisses the pad. It rides along with the tap's ordinary
        // meaning rather than replacing it, so the terminal still takes focus.
        terminalInput.onTap = { [weak self] in
            guard let self, let pane = session.selectedPaneId else { return }
            arrowPads.hide(pane)
            showArrowPad()
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
        for subview in [terminalView, terminalInput, paneRow, bottomBar, statusPill] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Above the input view and never inside it: that view carries the scroll pan
        // recognizer as well as tap-to-focus and long-press, so a pad in its subtree would
        // give its own drag and taps to all three. It is placed by frame from the resolved
        // placement, so it takes no constraint -- and it stays below the bar and the pill,
        // which the region it is resolved against also keeps it clear of.
        arrowPad.isHidden = true
        view.insertSubview(arrowPad, aboveSubview: terminalInput)
        // The chrome sits under the input view, which must keep every touch: its own pan
        // recognizer is moved onto that view instead, so a swipe scrolls while tap-to-focus
        // and long-press stay where they were. It sizes itself to the drawn grid rather
        // than to the terminal's extent, so it is placed by frame and takes no constraint.
        let scrollChrome = session.scrollChrome
        view.insertSubview(scrollChrome, aboveSubview: terminalView)
        terminalInput.addGestureRecognizer(scrollChrome.panGestureRecognizer)
        configureConstraints()
    }

    /// Draws the session actions the model offers right now. It is asked when the menu
    /// opens, so the list is the one the model states at that moment.
    ///
    /// The switch is exhaustive over the kit's action vocabulary, so an action added there
    /// stops this target building rather than going missing from the menu. Each item
    /// carries an event rather than the request the facts imply at that instant -- the
    /// model builds the request when it handles the event.
    private func sessionMenuItems() -> [TerminalBarMenuItem] {
        session.projection.sessionActions.map { action in
            switch action {
            case .newPane:
                TerminalBarMenuItem(
                    title: "New pane",
                    systemImage: "rectangle.split.2x1"
                ) { [weak self] in self?.session.dispatch(.newPaneRequested) }
            case .claim:
                TerminalBarMenuItem(
                    title: "Claim",
                    systemImage: "arrow.down.right.and.arrow.up.left"
                ) { [weak self] in self?.session.dispatch(.claimRequested) }
            case .release:
                TerminalBarMenuItem(
                    title: "Release",
                    systemImage: "arrow.up.left.and.arrow.down.right"
                ) { [weak self] in self?.session.dispatch(.releaseRequested) }
            }
        }
    }

    private func configureConstraints() {
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            // Full bleed: the terminal owns the whole width and everything from the
            // physical top of the window down to the row's rest position. Nothing is
            // allowed to take vertical space above it -- the pill floats over it instead.
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            // The resting position of the row and the bar together, not the views
            // themselves: the keyboard is a presentation offset, never a geometry input,
            // so the terminal's bounds -- and with them the grid a claim names and the
            // pixels the frame stores hold -- must not move when they ride the keyboard
            // up. Both heights are constants, so nothing either of them shows can move the
            // terminal either. The rise is measured in `viewDidLayoutSubviews` and handed
            // to the surface as one scalar.
            terminalView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -(TerminalPaneRowView.height + TerminalBottomBarView.height)
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

            // The row sits beside the terminal rather than over it, so no cell is ever
            // drawn underneath it. It rides the keyboard on top of the bar, which keeps
            // both of its affordances reachable while the user is typing.
            paneRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneRow.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            paneRow.heightAnchor.constraint(equalToConstant: TerminalPaneRowView.height),

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
        let color = projection.status.color
        // The row is the permanent half: it names the pane and reads the connection as a
        // color, whatever the connection is doing.
        paneRow.show(connectionColor: color, paneTitle: projection.selectedPaneTitle)
        statusPill.show(status: projection.status.text, color: color)
        // Whether the status is worth a pill at all is the model's decision, never a
        // severity the shell re-reads: `connecting` and `disconnected` are normal severity
        // and still have words. Written only on a change, because `isHidden` dirties its
        // superview's layout even when it is given the value it already holds.
        let restsNow = projection.status.isResting
        if statusPill.isHidden != restsNow { statusPill.isHidden = restsNow }
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
        // again when it opens, from the same list this reads.
        bottomBar.setMenuOffered(projection.sessionActions.isEmpty == false)
        // The latch is a session fact like any other: the highlight follows the
        // projection, so an input that spent the latch unlights the key with no Ctrl tap.
        bottomBar.setLatchedModifiers(projection.latchedModifiers)
        // The pad follows the selected pane, so a pane the user comes back to shows the
        // pad exactly as they left it.
        showArrowPad()
    }

    /// Sends one accessory key from whichever control reported it, so the pad's arrows and
    /// the bottom row's keys take the identical path into the session.
    private func sendAccessoryKey(_ key: MobileAccessoryKey) {
        // Read before the dispatch, so what is restored is the focus the tap found
        // rather than anything handling the key may have changed.
        let hadFocus = terminalInput.isFirstResponder
        session.dispatch(.accessoryKeyPressed(key))
        // The key was aimed at the terminal, so the terminal keeps the focus a tap on
        // the control would otherwise have taken -- but only when it already held it. A
        // key pressed with the keyboard down must not summon the keyboard: it is
        // raised by the keyboard button or by a tap on the grid, never as a side
        // effect of typing one of these keys.
        if hadFocus { terminalInput.becomeFirstResponder() }
    }

    /// Shows or hides the selected pane's pad, lights the bar's toggle to match, and puts
    /// the pad where the pane's stored preference says.
    ///
    /// It resolves the placement itself rather than asking for a layout pass: this runs on
    /// every redraw, and one `setNeedsLayout` per published frame would put a whole layout
    /// pass behind the terminal's output.
    private func showArrowPad() {
        let shown = session.selectedPaneId.map(arrowPads.isVisible) ?? false
        bottomBar.setArrowPadShown(shown)
        // Written only on a change: `isHidden` dirties its superview's layout even when the
        // value it is given is the one it already holds.
        if arrowPad.isHidden != (shown == false) { arrowPad.isHidden = shown == false }
        layoutArrowPad()
    }

    /// The rectangle the pad is allowed to sit in: the safe area above and beside it, and
    /// the keyboard-riding row below it.
    ///
    /// The pill is deliberately not subtracted. It comes and goes with the connection, and
    /// a region that shrank around it would move every pad parked near the top each time
    /// the connection changed. A shown pill may therefore overlap the pad, which is the
    /// cheaper of the two: the pill is rare, and the pad is where the user put it.
    private func arrowPadRegion() -> CGRect {
        let margin = Self.arrowPadMargin
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let minX = safe.minX + margin
        let maxX = safe.maxX - margin
        let minY = safe.minY + margin
        let maxY = paneRow.frame.minY - margin
        return CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }

    /// Resolves the selected pane's stored preference against the region as it is now.
    ///
    /// It does nothing while a finger is down: the drag owns the pad's frame until it
    /// ends, and a layout pass that re-resolved mid-drag would fight it.
    private func layoutArrowPad() {
        guard arrowPad.isHidden == false, arrowPadDrag == nil else { return }
        guard let pane = session.selectedPaneId else { return }
        let region = arrowPadRegion()
        let placement = MobileArrowPadPlacement(
            position: arrowPads.position(pane),
            padSize: TerminalArrowPadView.size,
            regionSize: region.size
        )
        arrowPad.frame = arrowPadFrame(placement: placement, in: region)
    }

    /// Turns a leading/top placement into a frame, mirroring the leading inset for a
    /// right-to-left interface -- the one interface-direction fact the pure placement
    /// deliberately leaves to UIKit.
    private func arrowPadFrame(
        placement: MobileArrowPadPlacement,
        in region: CGRect
    ) -> CGRect {
        let size = TerminalArrowPadView.size
        let x = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? region.maxX - placement.leadingInset - size.width
            : region.minX + placement.leadingInset
        return CGRect(
            x: x,
            y: region.minY + placement.topInset,
            width: size.width,
            height: size.height
        )
    }

    /// Moves the pad under the finger and commits the result when the finger lifts.
    ///
    /// The commit names the pane the drag began on rather than the one selected when it
    /// ends, so a pane change mid-drag cannot move the newly selected pane's pad. A
    /// cancelled drag commits nothing and the next layout pass restores the stored place.
    private func dragArrowPad(_ recognizer: UIPanGestureRecognizer) {
        let region = arrowPadRegion()
        let isRightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        switch recognizer.state {
        case .began:
            guard let pane = session.selectedPaneId else { return }
            let placement = MobileArrowPadPlacement(
                position: arrowPads.position(pane),
                padSize: TerminalArrowPadView.size,
                regionSize: region.size
            )
            arrowPadDrag = (pane, placement.leadingInset, placement.topInset)
        case .changed, .ended:
            guard let drag = arrowPadDrag else { return }
            let translation = recognizer.translation(in: view)
            // A leading inset grows as the pad moves away from the leading edge, which is
            // leftward in a right-to-left interface.
            let leading = drag.leadingInset + (isRightToLeft ? -translation.x : translation.x)
            let top = drag.topInset + translation.y
            let moved = arrowPads.position(drag.pane).moved(
                toLeadingInset: leading,
                topInset: top,
                padSize: TerminalArrowPadView.size,
                regionSize: region.size
            )
            if recognizer.state == .ended {
                arrowPadDrag = nil
                arrowPads.move(drag.pane, to: moved)
                layoutArrowPad()
                return
            }
            let placement = MobileArrowPadPlacement(
                position: moved,
                padSize: TerminalArrowPadView.size,
                regionSize: region.size
            )
            arrowPad.frame = arrowPadFrame(placement: placement, in: region)
        case .cancelled, .failed:
            // Nothing is committed, so the stored place is restored as it was.
            arrowPadDrag = nil
            layoutArrowPad()
        case .possible:
            break
        @unknown default:
            arrowPadDrag = nil
            layoutArrowPad()
        }
    }

    /// Opens the form that names a server. The sheet is built for this one presentation
    /// and seeded from the model's draft, so the fields are the draft's editor only while
    /// they are on screen and no redraw can rewrite what the user is typing.
    ///
    /// It is a medium-detent sheet so the terminal it is about stays visible behind it.
    /// The status the form needs is repeated inside the sheet, so it is readable there
    /// whether or not a pill is up.
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
    /// Medium detent only, as the connect sheet is: the terminal the list is about stays
    /// visible behind it. A list too long for the detent scrolls inside it.
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
}

private extension MobileStatusLine {
    /// The one UIKit decision the composed status leaves to the shell.
    ///
    /// A resting status is green rather than the quiet grey its severity would give it.
    /// Severity cannot make that call: `connecting` and `disconnected` are `.normal` too,
    /// and painting those green would say the connection was up while it was away. Resting
    /// is the fact that means healthy, and the dot is the only thing that says so -- the
    /// pill is gone by then.
    var color: UIColor {
        if isResting { return .systemGreen }
        switch severity {
        case .normal: return .secondaryLabel
        case .degraded: return .systemOrange
        case .failed: return .systemRed
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
