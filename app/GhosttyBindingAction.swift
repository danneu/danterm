// Single chokepoint for dispatching Ghostty key-binding action strings to a surface.
// The libghostty C call `ghostty_surface_binding_action` takes a (pointer, byte-length)
// pair, which forces every caller into the same `withCString` + length dance; that
// boilerplate used to be copy-pasted across runtime and view code. This file keeps
// the remaining adapter call sites consistent and backend-private. It belongs in
// the app target because it touches GhosttyKit; keep pure model/update logic out.

import GhosttyKit

/// Sends a Ghostty key-binding action string to a surface via the C API,
/// centralizing the withCString + length dance inside the Ghostty adapter.
@discardableResult
func sendBindingAction(_ surface: ghostty_surface_t, _ action: String) -> Bool {
    action.withCString { ptr in
        ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
}
