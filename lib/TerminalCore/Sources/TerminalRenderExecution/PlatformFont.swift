// The single platform-font dependency of this module: the name of the system
// monospace face, which seeds the default grid metrics. Everything else the
// renderer draws with comes from CoreText and CoreGraphics, which are portable,
// so the AppKit/UIKit divide is confined to this file instead of spreading
// through the renderer. Nothing else belongs here.
#if canImport(AppKit)
import AppKit

/// Names the framework font type so the renderer names neither AppKit nor UIKit.
/// Both spell `monospacedSystemFont(ofSize:weight:)` and `fontName` the same
/// way, and those two members are all this module asks of it.
typealias PlatformFont = NSFont
#else
import UIKit

typealias PlatformFont = UIFont
#endif
