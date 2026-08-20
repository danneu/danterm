// The one row of controls between the terminal and the keyboard.
//
// It holds the terminal keys a software keyboard has no room for, the way into the pane
// picker, the overflow menu the session actions live in, and keyboard dismissal. Its
// height is fixed by its own constraints and not by what it currently offers, so the
// terminal above it -- and with it the grid a claim would name -- never moves when an
// action appears or goes away.
//
// What does not belong here: any session fact. The bar reports gestures, and it asks for
// its menu items at the moment the menu opens rather than remembering what was offered
// when it last drew.
import DanTermMobileKit
import UIKit

/// One action the overflow menu offers, named at the moment the menu opens.
///
/// It carries a closure, never a request: the closure sends an event, and the session
/// model builds the request from the facts it holds when it handles that event. A menu
/// left open while the Mac takes the pane back therefore cannot send a stale request.
struct TerminalBarMenuItem {
    let title: String
    let systemImage: String
    let perform: @MainActor () -> Void
}

/// Places the bottom row's controls and reports every tap on it as a gesture.
@MainActor
final class TerminalBottomBarView: UIView {
    var onPaneList: (() -> Void)?
    /// Reports an accessory key. The Ctrl key's highlight is not decided here: it is
    /// rendered from the session projection on the redraw path, like every other fact.
    var onAccessoryKey: ((MobileAccessoryKey) -> Void)?
    var onDismissKeyboard: (() -> Void)?
    /// Asked every time the overflow menu opens, so the menu shows what is offered now
    /// rather than what was offered when the bar last drew.
    var menuItems: (() -> [TerminalBarMenuItem])?

    /// The bar's fixed height. Every control in it is sized to this row, so the row is the
    /// same height whether or not the overflow menu has anything in it.
    static let height: CGFloat = 44

    private let paneButton = UIButton(type: .system)
    private let keyRow = UIStackView()
    private let overflowButton = UIButton(type: .system)
    private let keyboardDismissButton = UIButton(type: .system)
    private weak var controlButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Opaque, because a partial keyboard lift leaves live rows behind this strip;
        // no cell may show through the bar.
        backgroundColor = .black
        configureViews()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Offers or withholds the overflow menu. The items themselves are asked for when the
    /// menu opens; this only says whether there is anything to open it for.
    func setMenuOffered(_ offered: Bool) {
        // Written only on a change: a layout pass feeds the redraw this comes from, and a
        // button's enabled state schedules its own layout, so an unconditional write would
        // drive a layout loop.
        guard overflowButton.isEnabled != offered else { return }
        overflowButton.isEnabled = offered
    }

    private func configureViews() {
        configureChromeButton(paneButton, systemImage: "square.grid.2x2")
        paneButton.addTarget(self, action: #selector(paneListTapped), for: .touchUpInside)

        configureChromeButton(overflowButton, systemImage: "ellipsis.circle")
        overflowButton.showsMenuAsPrimaryAction = true
        // Uncached: the provider runs on every presentation, so the items are built from
        // the facts that hold at the moment the user opens the menu.
        overflowButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                let items = self?.menuItems?() ?? []
                completion(items.map { item in
                    UIAction(
                        title: item.title,
                        image: UIImage(systemName: item.systemImage)
                    ) { _ in item.perform() }
                })
            },
        ])

        configureChromeButton(keyboardDismissButton, systemImage: "keyboard.chevron.compact.down")
        keyboardDismissButton.addTarget(
            self,
            action: #selector(dismissKeyboard),
            for: .touchUpInside
        )

        keyRow.axis = .horizontal
        keyRow.alignment = .fill
        keyRow.distribution = .fillEqually
        keyRow.spacing = 2
        for entry in terminalAccessoryEntries {
            let button = makeKeyButton(entry)
            keyRow.addArrangedSubview(button)
            if entry.tag == 1 { controlButton = button }
        }

        for subview in [paneButton, keyRow, overflowButton, keyboardDismissButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    /// Gives the three non-key controls one narrow appearance, so the keys keep as much of
    /// the row's width as the phone can spare.
    private func configureChromeButton(_ button: UIButton, systemImage: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImage)
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 0
        )
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .body
        )
        button.configuration = configuration
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            paneButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            paneButton.topAnchor.constraint(equalTo: topAnchor),
            paneButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            paneButton.widthAnchor.constraint(equalToConstant: 36),

            keyRow.leadingAnchor.constraint(equalTo: paneButton.trailingAnchor, constant: 4),
            keyRow.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -4),
            keyRow.topAnchor.constraint(equalTo: topAnchor),
            keyRow.bottomAnchor.constraint(equalTo: bottomAnchor),

            overflowButton.trailingAnchor.constraint(
                equalTo: keyboardDismissButton.leadingAnchor
            ),
            overflowButton.topAnchor.constraint(equalTo: topAnchor),
            overflowButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: 36),

            keyboardDismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            keyboardDismissButton.topAnchor.constraint(equalTo: topAnchor),
            keyboardDismissButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            keyboardDismissButton.widthAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func makeKeyButton(_ entry: TerminalAccessoryEntry) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 0
        )
        configuration.title = entry.systemImage == nil ? entry.title : nil
        configuration.titleLineBreakMode = .byClipping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        configuration.image = entry.systemImage.flatMap(UIImage.init(systemName:))
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .body
        )
        let button = UIButton(configuration: configuration)
        button.tag = entry.tag
        button.titleLabel?.numberOfLines = 1
        button.addTarget(self, action: #selector(accessoryTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func paneListTapped() {
        onPaneList?()
    }

    /// Renders the Ctrl key's highlight from the projection's latch state. Written only
    /// on a change, for the same layout-loop reason as `setMenuOffered`.
    func setControlLatched(_ latched: Bool) {
        guard let controlButton, controlButton.isSelected != latched else { return }
        controlButton.isSelected = latched
        var configuration = controlButton.configuration
        configuration?.baseForegroundColor = latched ? .systemOrange : tintColor
        controlButton.configuration = configuration
    }

    @objc private func accessoryTapped(_ sender: UIButton) {
        guard let key = MobileAccessoryKey(tag: sender.tag) else { return }
        onAccessoryKey?(key)
    }

    @objc private func dismissKeyboard() {
        onDismissKeyboard?()
    }
}

/// Describes one terminal key without coupling its presentation to input mapping.
private struct TerminalAccessoryEntry {
    let title: String
    let systemImage: String?
    let tag: Int
}

private let terminalAccessoryEntries = [
    TerminalAccessoryEntry(
        title: "Esc", systemImage: nil, tag: 0
    ),
    TerminalAccessoryEntry(
        title: "Ctrl", systemImage: nil, tag: 1
    ),
    TerminalAccessoryEntry(
        title: "Tab", systemImage: nil, tag: 2
    ),
    TerminalAccessoryEntry(
        title: "Up", systemImage: "arrow.up", tag: 3
    ),
    TerminalAccessoryEntry(
        title: "Down", systemImage: "arrow.down", tag: 4
    ),
    TerminalAccessoryEntry(
        title: "Left", systemImage: "arrow.left", tag: 5
    ),
    TerminalAccessoryEntry(
        title: "Right", systemImage: "arrow.right", tag: 6
    ),
    TerminalAccessoryEntry(
        title: "|", systemImage: nil, tag: 7
    ),
    TerminalAccessoryEntry(
        title: "~", systemImage: nil, tag: 8
    ),
    TerminalAccessoryEntry(
        title: "/", systemImage: nil, tag: 9
    ),
]

private extension MobileAccessoryKey {
    init?(tag: Int) {
        switch tag {
        case 0: self = .escape
        case 1: self = .control
        case 2: self = .tab
        case 3: self = .up
        case 4: self = .down
        case 5: self = .left
        case 6: self = .right
        case 7: self = .pipe
        case 8: self = .tilde
        case 9: self = .slash
        default: return nil
        }
    }
}
