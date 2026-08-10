// Shared AppKit extraction for turning a terminal drop pasteboard into pure drag input.
import Cocoa

/// Keeps both terminal backends on one pasteboard-type and priority path before pure quoting.
func dragDropContent(from pasteboard: NSPasteboard) -> String? {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    let filePaths = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
    let urlString = pasteboard.string(forType: .URL)
    let plainString = pasteboard.string(forType: .string)
    return DragDropInput.buildContent(
        filePaths: filePaths,
        urlString: urlString,
        plainString: plainString
    )
}
