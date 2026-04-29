// Non-activating NSPanel that renders the MRU tab switcher overlay. Built
// once at app launch, shown and hidden via Effects driven by mruCycle state.
// Uses domain-pure ResolvedCycle/SwitcherRow types for rendering so the
// view layer never reads frozenOrder/cursorIndex directly.

import Cocoa

struct SwitcherRow: Equatable {
    let tabId: TabId
    let name: String
    let color: TabColor?
    let alertCount: Int
}

final class SwitcherPanel: NSPanel {
    private static let panelWidth: CGFloat = 320

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SwitcherPanel.panelWidth, height: 1),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        contentView = SwitcherContentView()
    }

    // Non-activating: refuse to become key/main so the focused terminal pane
    // keeps first-responder while the overlay is visible.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Render the overlay from current model state. Routed through
    // resolveLiveCycle so a tab removed mid-cycle doesn't leave a stale
    // highlight or crash on out-of-bounds.
    func render(from model: AppModel) {
        guard
            let cycle = model.mruCycle,
            let resolved = resolveLiveCycle(cycle, in: model),
            let view = contentView as? SwitcherContentView
        else { return }

        let rows = resolved.liveOrder.compactMap { tabId -> SwitcherRow? in
            guard let tab = tabById(tabId, in: model) else { return nil }
            return SwitcherRow(
                tabId: tabId,
                name: tab.displayTitle,
                color: tab.color,
                alertCount: unreadAlertCount(for: tab, alerts: model.alerts)
            )
        }
        view.update(rows: rows, cursorIndex: resolved.cursorIndex)

        let height = max(1, CGFloat(rows.count) * SwitcherContentView.rowHeight
                          + SwitcherContentView.padding * 2)
        setContentSize(NSSize(width: SwitcherPanel.panelWidth, height: height))
    }

    // Position the panel centered on the screen of the given window.
    func centerOnScreen(of window: NSWindow?) {
        let screen = window?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let panelFrame = self.frame
        let x = frame.midX - panelFrame.width / 2
        let y = frame.midY - panelFrame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// Plain AppKit content view: NSVisualEffectView background + NSStackView of
// row views. SwiftUI was avoided to keep first-frame latency low.
final class SwitcherContentView: NSView {
    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 8

    private let backgroundView: NSVisualEffectView
    private let stackView: NSStackView
    private var rowViews: [SwitcherRowView] = []

    override init(frame frameRect: NSRect) {
        backgroundView = NSVisualEffectView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 0.5
        backgroundView.layer?.borderColor = NSColor.separatorColor.cgColor

        stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.alignment = .leading
        stackView.distribution = .fill

        super.init(frame: frameRect)

        addSubview(backgroundView)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stackView.topAnchor.constraint(equalTo: topAnchor, constant: SwitcherContentView.padding),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SwitcherContentView.padding),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherContentView.padding),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SwitcherContentView.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(rows: [SwitcherRow], cursorIndex: Int) {
        // Grow / shrink the row pool to match. Rows are reused across renders.
        while rowViews.count < rows.count {
            let row = SwitcherRowView()
            rowViews.append(row)
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: SwitcherContentView.rowHeight).isActive = true
        }
        while rowViews.count > rows.count {
            let row = rowViews.removeLast()
            stackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        for (i, row) in rows.enumerated() {
            rowViews[i].apply(row: row, isCursor: i == cursorIndex)
        }
    }
}

// One pre-built row. Reused across renders to avoid per-frame allocation.
final class SwitcherRowView: NSView {
    private let nameLabel: NSTextField
    private let badgeLabel: NSTextField
    private let colorDot: NSView
    private let highlightLayer: CALayer

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor

        colorDot = NSView()
        colorDot.translatesAutoresizingMaskIntoConstraints = false
        colorDot.wantsLayer = true
        colorDot.layer?.cornerRadius = 4

        highlightLayer = CALayer()
        highlightLayer.cornerRadius = 4

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.addSublayer(highlightLayer)

        addSubview(colorDot)
        addSubview(nameLabel)
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            colorDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            colorDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorDot.widthAnchor.constraint(equalToConstant: 8),
            colorDot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: colorDot.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        // Inset the highlight slightly so it doesn't touch the panel border.
        highlightLayer.frame = bounds.insetBy(dx: 4, dy: 2)
    }

    func apply(row: SwitcherRow, isCursor: Bool) {
        nameLabel.stringValue = row.name
        if row.alertCount > 0 {
            badgeLabel.stringValue = "\u{2022} \(row.alertCount)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        }
        colorDot.layer?.backgroundColor = (row.color?.nsColor ?? .clear).cgColor
        colorDot.isHidden = (row.color == nil)
        highlightLayer.backgroundColor = isCursor
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
            : NSColor.clear.cgColor
    }
}
