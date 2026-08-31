// Builds the main window's content hierarchy -- the chrome bar above the
// sidebar | content split -- for the production window and the UI-test
// fixture alike. One builder, so the fixture cannot drift from production
// wiring: a hand-mirrored fixture is how a resize-blocking constraint once
// escaped every sidebar test. Window creation and chrome-button wiring stay
// with the caller; only the view hierarchy and its constraints live here.
import Cocoa

/// The views `makeMainWindowContent` builds, so every caller wires the same
/// pieces into the window, the runtime, and the split-view delegate.
@MainActor
struct MainWindowContent {
    let rootView: NSView
    let splitView: NSSplitView
    let sidebarView: SidebarView
    let contentArea: NSView
}

/// Builds the production content hierarchy: chrome pinned to the top, the
/// sidebar | content split filling the rest.
@MainActor
func makeMainWindowContent(
    chromeView: WindowChromeView,
    splitViewDelegate: NSSplitViewDelegate
) -> MainWindowContent {
    let splitView = NSSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.translatesAutoresizingMaskIntoConstraints = false

    let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: minSidebarWidth, height: 600))
    let contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    // Both arranged subviews are constraint-based, so NSSplitView owns the
    // divider layout. Translated autoresizing masks would become required
    // size constraints that pin the window to its exact frame -- the resize
    // bug this builder exists to prevent.
    sidebarView.translatesAutoresizingMaskIntoConstraints = false
    contentArea.translatesAutoresizingMaskIntoConstraints = false

    splitView.addArrangedSubview(sidebarView)
    splitView.addArrangedSubview(contentArea)

    // Window resize goes to the content area: the sidebar holds its width at
    // one priority above it in constraint-driven sizing passes (the delegate's
    // shouldAdjustSizeOfSubview covers the split view's own resize pass). Both
    // priorities stay far below NSLayoutPriorityDragThatCannotResizeWindow
    // (490), so neither holds against a window resize (NSSplitView.h).
    splitView.setHoldingPriority(
        NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 1),
        forSubviewAt: 0
    )
    splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

    splitView.delegate = splitViewDelegate

    let rootView = NSView()
    rootView.addSubview(chromeView)
    rootView.addSubview(splitView)

    NSLayoutConstraint.activate([
        chromeView.topAnchor.constraint(equalTo: rootView.topAnchor),
        chromeView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
        chromeView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

        splitView.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
        splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
        splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
        splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])

    return MainWindowContent(
        rootView: rootView,
        splitView: splitView,
        sidebarView: sidebarView,
        contentArea: contentArea
    )
}
