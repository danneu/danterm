// A drop-side test double shared by the pane and tab TODO popover suites.
// Both `acceptDrop` implementations read nothing from NSDraggingInfo except
// the dragging pasteboard, so the double answers every other requirement with
// an inert value. Keep suite-specific fixtures and assertions out of here.
import Cocoa

/// Stands in for the NSDraggingInfo AppKit would hand a drop handler, so the
/// suites can drive `acceptDrop` without a real drag session.
final class FakeTodoDraggingInfo: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

/// Build dragging info carrying one pasteboard item, the only payload shape
/// either TODO popover drop handler decodes.
func todoDraggingInfo(type: NSPasteboard.PasteboardType, string: String) -> FakeTodoDraggingInfo {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(string, forType: type)
    pasteboard.writeObjects([item])
    return FakeTodoDraggingInfo(pasteboard: pasteboard)
}
