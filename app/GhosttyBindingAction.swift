// Single chokepoint for dispatching Ghostty key-binding action strings to a surface.
// The libghostty C call `ghostty_surface_binding_action` takes a (pointer, byte-length)
// pair, which forces every caller into the same `withCString` + length dance; that
// boilerplate was copy-pasted across the runtime and the terminal views. This file
// holds the one free helper they all route through. Lives on its own so any call site
// (AppRuntime, TerminalView, ScrollableTerminalView) can reach it without coupling to
// a particular view type. Belongs in the app target because it touches GhosttyKit;
// keep pure model/update logic out of here.

import GhosttyKit

/// Sends a Ghostty key-binding action string to a surface via the C API,
/// centralizing the withCString + length dance that was copy-pasted across
/// the runtime and terminal views.
@discardableResult
func sendBindingAction(_ surface: ghostty_surface_t, _ action: String) -> Bool {
    action.withCString { ptr in
        ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
}
