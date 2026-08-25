// The one row of controls between the terminal and the keyboard.
//
// It holds the terminal keys a software keyboard has no room for, the way into the pane
// picker, the overflow menu the session actions live in, and the keyboard toggle. Its
// height is fixed by its own constraints and not by what it currently offers, so the
// terminal above it -- and with it the grid a claim would name -- never moves when an
// action appears or goes away.
//
// What does not belong here: any session fact. The bar reports gestures, and it asks for
// its menu items at the moment the menu opens rather than remembering what was offered
// when it last drew.
import DanTermMobileKit
import DanTermProtocol
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
    /// Reports an accessory key. A latch key's highlight is not decided here: it is
    /// rendered from the session projection on the redraw path, like every other fact.
    var onAccessoryKey: ((MobileAccessoryKey) -> Void)?
    /// Reports the keyboard button. The bar does not know whether the keyboard is up:
    /// the controller owns the focus and says which face the button wears.
    var onToggleKeyboard: (() -> Void)?
    /// Asked every time the overflow menu opens, so the menu shows what is offered now
    /// rather than what was offered when the bar last drew.
    var menuItems: (() -> [TerminalBarMenuItem])?

    /// The bar's fixed height. Every control in it is sized to this row, so the row is the
    /// same height whether or not the overflow menu has anything in it.
    static let height: CGFloat = 44

    private static let keyboardShownImage = "keyboard.chevron.compact.down"
    private static let keyboardHiddenImage = "keyboard"

    private let paneButton = UIButton(type: .system)
    private let keyRow = UIStackView()
    private let overflowButton = UIButton(type: .system)
    private let keyboardToggleButton = UIButton(type: .system)
    /// The latch keys by the modifier they arm, so the highlight pass writes each one
    /// from the projection without naming a particular key.
    private var latchButtons: [(modifier: KeyMods, button: UIButton)] = []
    /// The face the keyboard button currently wears, so `setKeyboardShown` can write only
    /// on a change without asking a `UIImage` whether it is the same symbol.
    private var keyboardShown = false

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

    /// Says which way the keyboard button points: down to put the keyboard away while it
    /// is up, and a plain keyboard to call it back while it is down.
    ///
    /// Written only on a change, for the same layout-loop reason as `setMenuOffered`.
    func setKeyboardShown(_ shown: Bool) {
        guard keyboardShown != shown else { return }
        keyboardShown = shown
        let name = shown ? Self.keyboardShownImage : Self.keyboardHiddenImage
        var configuration = keyboardToggleButton.configuration
        configuration?.image = UIImage(systemName: name)
        keyboardToggleButton.configuration = configuration
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

        configureChromeButton(keyboardToggleButton, systemImage: Self.keyboardHiddenImage)
        keyboardToggleButton.addTarget(
            self,
            action: #selector(toggleKeyboard),
            for: .touchUpInside
        )

        keyRow.axis = .horizontal
        keyRow.alignment = .fill
        keyRow.distribution = .fillEqually
        keyRow.spacing = 2
        for key in MobileAccessoryKey.allCases {
            let button = makeKeyButton(key)
            keyRow.addArrangedSubview(button)
            if let modifier = MobileInputMapper.latchModifier(for: key) {
                latchButtons.append((modifier, button))
            }
        }

        for subview in [paneButton, keyRow, overflowButton, keyboardToggleButton] {
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
                equalTo: keyboardToggleButton.leadingAnchor
            ),
            overflowButton.topAnchor.constraint(equalTo: topAnchor),
            overflowButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: 36),

            keyboardToggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            keyboardToggleButton.topAnchor.constraint(equalTo: topAnchor),
            keyboardToggleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            keyboardToggleButton.widthAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func makeKeyButton(_ key: MobileAccessoryKey) -> UIButton {
        let appearance = TerminalAccessoryAppearance(key)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 0
        )
        configuration.title = appearance.systemImage == nil ? appearance.title : nil
        configuration.titleLineBreakMode = .byClipping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        configuration.image = appearance.systemImage.flatMap(UIImage.init(systemName:))
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .body
        )
        let button = UIButton(configuration: configuration)
        button.titleLabel?.numberOfLines = 1
        // The action carries the key it was built for, so a button cannot report a key
        // other than the one the row drew it as. It is added rather than passed as the
        // primary action, because a primary action would backfill its title onto the
        // image-only buttons.
        button.addAction(
            UIAction { [weak self] _ in self?.onAccessoryKey?(key) },
            for: .touchUpInside
        )
        return button
    }

    @objc private func paneListTapped() {
        onPaneList?()
    }

    /// Renders each latch key's highlight from the projection's armed modifiers, so the
    /// row lights exactly what the next input will carry. Written only on a change, for
    /// the same layout-loop reason as `setMenuOffered`.
    func setLatchedModifiers(_ modifiers: KeyMods) {
        for (modifier, button) in latchButtons {
            let latched = modifiers.contains(modifier)
            guard button.isSelected != latched else { continue }
            button.isSelected = latched
            var configuration = button.configuration
            configuration?.baseForegroundColor = latched ? .systemOrange : tintColor
            button.configuration = configuration
        }
    }

    @objc private func toggleKeyboard() {
        onToggleKeyboard?()
    }
}

/// Says how one terminal key is drawn, without coupling its presentation to input
/// mapping: the kit enum names the input vocabulary, and this switch is the only place
/// that gives a case a face. It has no `default`, so a new key cannot reach the row until
/// the row says how to draw it.
private struct TerminalAccessoryAppearance {
    let title: String
    let systemImage: String?

    init(_ key: MobileAccessoryKey) {
        switch key {
        case .escape: self.init(title: "Esc", systemImage: nil)
        case .control: self.init(title: "Ctrl", systemImage: nil)
        case .shift: self.init(title: "Shift", systemImage: nil)
        case .tab: self.init(title: "Tab", systemImage: nil)
        case .up: self.init(title: "Up", systemImage: "arrow.up")
        case .down: self.init(title: "Down", systemImage: "arrow.down")
        case .left: self.init(title: "Left", systemImage: "arrow.left")
        case .right: self.init(title: "Right", systemImage: "arrow.right")
        case .pipe: self.init(title: "|", systemImage: nil)
        case .tilde: self.init(title: "~", systemImage: nil)
        case .slash: self.init(title: "/", systemImage: nil)
        }
    }

    private init(title: String, systemImage: String?) {
        self.title = title
        self.systemImage = systemImage
    }
}
