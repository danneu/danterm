// AppKit clipboard write surface for normalized Ghostty clipboard MIME items.
// This stays GhosttyKit-free so the UI harness can test MIME-to-pasteboard
// mapping and writes without linking libghostty or touching the system clipboard.
import AppKit
import UniformTypeIdentifiers

/// Minimal pasteboard API needed for clipboard writes, split out so tests can
/// record declare/set calls without using the real pasteboard service.
protocol ClipboardWriteSurface: AnyObject {
    @discardableResult func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner: Any?) -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: ClipboardWriteSurface {}

/// Map MIME types onto pasteboard types while pinning plain text to `.string`,
/// the exact type DanTerm's clipboard readers request.
func defaultClipboardTypeMap(_ mime: String) -> NSPasteboard.PasteboardType? {
    if mime == "text/plain" { return .string }
    guard let type = UTType(mimeType: mime) else { return nil }
    return NSPasteboard.PasteboardType(type.identifier)
}

/// Write mapped clipboard items to a pasteboard surface, leaving the surface
/// untouched when no item maps to a pasteboard type.
func writeClipboardItems(
    _ items: [ClipboardWriteItem],
    mapType: (String) -> NSPasteboard.PasteboardType? = defaultClipboardTypeMap,
    to surface: ClipboardWriteSurface
) {
    let mapped: [(type: NSPasteboard.PasteboardType, data: String)] =
        items.compactMap { item in mapType(item.mime).map { (type: $0, data: item.data) } }

    guard mapped.isEmpty == false else { return }
    surface.declareTypes(mapped.map(\.type), owner: nil)
    for item in mapped {
        surface.setString(item.data, forType: item.type)
    }
}
