// The one place in the app that knows where a dialog's buttons go. Every
// hand-rolled dialog surface -- the confirmation panel, the remote theme
// sheet, the todo editor -- builds its button row from here, so the macOS
// convention is stated once instead of re-derived at each call site.
//
// Header and toolbar button rows do not belong here: they are not dialog
// action rows and the trailing/default convention does not apply to them.
import Cocoa

/// Where one action sits in the macOS button order. The row, not the caller,
/// turns a role into a position, so no surface can order its buttons wrong.
enum DialogActionRole {
    case defaultAction
    case cancel
    case alternate
}

/// One button a dialog offers: what it says, what it costs, what it does.
struct DialogAction {
    let title: String
    let role: DialogActionRole
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let perform: () -> Void
}

/// The trailing-aligned action row every DanTerm dialog uses, so button order
/// and alignment are stated once instead of at each call site. The default
/// action is rightmost, cancel sits immediately left of it, and every other
/// action is separated toward the leading edge.
///
/// `reservesKeyEquivalents` decides whether the row claims Return and Escape.
/// A host that classifies those keys itself -- an editor whose text view acts
/// on Return, or a window whose `sendEvent` answers them before AppKit routes
/// the press -- passes `false` so the row's key equivalents cannot fight it.
/// The row's buttons and the host's key handling must funnel through the same
/// handlers, or the two paths can diverge in meaning.
@MainActor
final class DialogActionRow: NSView {
    private let stack = NSStackView()
    /// The drawn buttons, leading to trailing, paired with the action each one
    /// runs. Routing by identity keeps a button's handler its own after a
    /// `setActions` rebuild swaps every button out.
    private var entries: [(button: NSButton, action: DialogAction)] = []
    private let reservesKeyEquivalents: Bool

    /// Standard AppKit dialog button spacing, stated once for the whole app.
    private static let buttonSpacing: CGFloat = 12

    init(actions: [DialogAction], reservesKeyEquivalents: Bool = true) {
        self.reservesKeyEquivalents = reservesKeyEquivalents
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.distribution = .gravityAreas
        stack.alignment = .centerY
        stack.spacing = Self.buttonSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The row must stretch to the width its host gives it: the trailing
        // gravity area has nothing to pin against in a row sized to fit.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setActions(actions)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Replaces the whole row. Buttons are built fresh rather than hidden, so
    /// no button a dialog no longer offers can hold space in the layout.
    func setActions(_ actions: [DialogAction]) {
        for (button, _) in entries {
            stack.removeView(button)
        }
        entries = []

        let alternates = actions.filter { $0.role == .alternate }
        let cancel = actions.filter { $0.role == .cancel }
        let defaults = actions.filter { $0.role == .defaultAction }
        // Leading gravity first, then trailing: within the trailing area views
        // lay out in the order they are added, so cancel lands left of the
        // default and the pair hugs the trailing edge together.
        for action in alternates { add(action, in: .leading) }
        for action in cancel + defaults { add(action, in: .trailing) }

        if let first = entries.first?.button {
            NSLayoutConstraint.activate(entries.dropFirst().map {
                $0.button.heightAnchor.constraint(equalTo: first.heightAnchor)
            })
        }
    }

    /// The drawn buttons, leading to trailing. Callers derive a key-view chain
    /// or a test assertion from this rather than restating the order.
    var buttonsInVisualOrder: [NSButton] { entries.map(\.button) }

    func button(for role: DialogActionRole) -> NSButton? {
        entries.first { $0.action.role == role }?.button
    }

    private func add(_ action: DialogAction, in gravity: NSStackView.Gravity) {
        let button = NSButton(title: action.title, target: self, action: #selector(buttonClicked(_:)))
        button.bezelStyle = .push
        button.hasDestructiveAction = action.isDestructive
        button.isEnabled = action.isEnabled
        if reservesKeyEquivalents {
            switch action.role {
            // Return also paints the default button blue.
            case .defaultAction: button.keyEquivalent = "\r"
            case .cancel: button.keyEquivalent = "\u{1b}"
            case .alternate: break
            }
        }
        // A long alternate title truncates rather than widening the dialog. The
        // alternate keeps NSButton's default resistance and cancel and the
        // default are raised above it, so the alternate is the one that gives.
        if action.role == .alternate {
            button.lineBreakMode = .byTruncatingTail
        } else {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        stack.addView(button, in: gravity)
        entries.append((button, action))
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        entries.first { $0.button === sender }?.action.perform()
    }
}
