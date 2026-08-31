// Applies the model-owned sidebar presentation to the persistent AppKit hosts.
import Cocoa

/// Gives the reconciler one route to the sidebar divider and matching chrome.
@MainActor
protocol SidebarPresentationSurface: AnyObject {
    func applySidebarPresentation(_ presentation: SidebarPresentation)
}
