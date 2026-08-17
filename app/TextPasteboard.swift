// The clipboard seam shared by every view that offers an explicit Copy action.
// It lives in its own file because two unrelated panels need it and neither owns
// it: the theme browser's Copy Name and the confirmation panel's Copy commands.
// Nothing but the write half belongs here -- a view that reads the clipboard
// (paste) goes through AppKit directly, because there is no test that wants to
// observe a read.
import Cocoa

/// Minimal clipboard write surface, split out so a test can observe a Copy
/// action without touching AppKit pasteboard services.
protocol TextPasteboard: AnyObject {
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: TextPasteboard {}
