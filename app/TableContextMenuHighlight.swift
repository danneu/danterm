// The one piece of plumbing shared by every table-backed context menu: it lets
// AppKit mark and outline the right-clicked row while each menu is still built
// fresh per click. Menu contents stay in the views that build them.
import Cocoa

extension NSTableView {
    /// Routes a freshly built context menu through AppKit's own `menu(for:)`.
    ///
    /// AppKit sets `clickedRow` and draws the context-menu outline on that row
    /// only from `NSTableView.menu(for:)`, and only when that call finds a menu
    /// on the view. A subclass that answers with its own menu and never
    /// delegates gets neither. So lend AppKit the built menu for the length of
    /// the call and take it back before returning: the outline is drawn, and
    /// the view stores no menu that could anchor a retain cycle through the
    /// items it carries.
    ///
    /// Pass `super.menu(for: event)` as `appKitMenu`; an extension cannot reach
    /// a subclass's `super`.
    func menuHighlightingClickedRow(_ built: NSMenu, appKitMenu: () -> NSMenu?) -> NSMenu? {
        menu = built
        defer { menu = nil }
        return appKitMenu()
    }
}
