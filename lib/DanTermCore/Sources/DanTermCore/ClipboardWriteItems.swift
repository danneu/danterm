// Pure clipboard-write normalization. Libghostty supplies MIME/data pairs and
// the app layer maps those MIME types to pasteboard types; this file owns only
// the deterministic filtering, deduplication, and ordering decision.

/// One clipboard payload from libghostty, kept app-neutral so write decisions
/// can be tested without AppKit or GhosttyKit.
struct ClipboardWriteItem: Equatable {
    let mime: String
    let data: String
}

/// Normalize raw clipboard items into the ordered list the pasteboard writer
/// should attempt to write.
func clipboardItemsToWrite(_ raw: [ClipboardWriteItem]) -> [ClipboardWriteItem] {
    var seenMimes = Set<String>()
    var items: [ClipboardWriteItem] = []
    items.reserveCapacity(raw.count)

    for item in raw {
        guard item.mime.isEmpty == false else { continue }
        guard seenMimes.insert(item.mime).inserted else { continue }
        items.append(item)
    }

    return items
}
