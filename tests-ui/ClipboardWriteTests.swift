// UI-harness coverage for mapping normalized clipboard MIME items to AppKit
// pasteboard types without touching the system pasteboard.
import Cocoa
import UniformTypeIdentifiers

/// Registers clipboard write-surface coverage in the GhosttyKit-free UI harness.
func clipboardWriteTests() {
    print("ClipboardWrite")

    uiTest("text/plain maps to string pasteboard type") {
        try uiExpect(defaultClipboardTypeMap("text/plain") == .string, "text/plain must map to .string")
    }

    uiTest("text/html maps to html type, not string") {
        let htmlType = NSPasteboard.PasteboardType(UTType.html.identifier)
        let mapped = defaultClipboardTypeMap("text/html")

        try uiExpect(mapped == htmlType, "text/html should map to \(htmlType.rawValue), got \(String(describing: mapped?.rawValue))")
        try uiExpect(mapped != .string, "text/html must not collapse to .string")
    }

    uiTest("mixed write declares and writes plain and html types in order") {
        let htmlType = NSPasteboard.PasteboardType(UTType.html.identifier)
        let recorder = RecordingClipboardSurface()

        writeClipboardItems([
            ClipboardWriteItem(mime: "text/plain", data: "hi"),
            ClipboardWriteItem(mime: "text/html", data: "<b>hi</b>"),
        ], to: recorder)

        try uiExpect(recorder.events == [
            .declare([.string, htmlType]),
            .set(.string, "hi"),
            .set(htmlType, "<b>hi</b>"),
        ], "unexpected mixed write events: \(recorder.events)")
    }

    uiTest("html-only write never writes string type") {
        let htmlType = NSPasteboard.PasteboardType(UTType.html.identifier)
        let recorder = RecordingClipboardSurface()

        writeClipboardItems([ClipboardWriteItem(mime: "text/html", data: "<b>x</b>")], to: recorder)

        try uiExpect(recorder.events == [
            .declare([htmlType]),
            .set(htmlType, "<b>x</b>"),
        ], "unexpected html-only write events: \(recorder.events)")
    }

    uiTest("empty plain data still writes string type") {
        let recorder = RecordingClipboardSurface()

        writeClipboardItems([ClipboardWriteItem(mime: "text/plain", data: "")], to: recorder)

        try uiExpect(recorder.events == [
            .declare([.string]),
            .set(.string, ""),
        ], "empty text/plain should clear .string via an empty write")
    }

    uiTest("unmappable MIME is skipped") {
        let recorder = RecordingClipboardSurface()

        writeClipboardItems([
            ClipboardWriteItem(mime: "text/plain", data: "hi"),
            ClipboardWriteItem(mime: "x/unknown", data: "junk"),
        ], mapType: { mime in mime == "text/plain" ? .string : nil }, to: recorder)

        try uiExpect(recorder.events == [
            .declare([.string]),
            .set(.string, "hi"),
        ], "only mappable items should be written")
    }

    uiTest("all-unmappable write leaves pasteboard untouched") {
        let recorder = RecordingClipboardSurface()

        writeClipboardItems(
            [ClipboardWriteItem(mime: "x/unknown", data: "junk")],
            mapType: { _ in nil },
            to: recorder
        )

        try uiExpect(recorder.events.isEmpty, "all-unmappable write must not declare or clear")
    }

    uiTest("empty write leaves pasteboard untouched") {
        let recorder = RecordingClipboardSurface()

        writeClipboardItems([], to: recorder)

        try uiExpect(recorder.events.isEmpty, "empty write must not declare or clear")
    }
}

private final class RecordingClipboardSurface: ClipboardWriteSurface {
    enum Event: Equatable, CustomStringConvertible {
        case declare([NSPasteboard.PasteboardType])
        case set(NSPasteboard.PasteboardType, String)

        var description: String {
            switch self {
            case .declare(let types):
                return "declare(\(types.map(\.rawValue)))"
            case .set(let type, let data):
                return "set(\(type.rawValue), \(data))"
            }
        }
    }

    private(set) var events: [Event] = []

    @discardableResult
    func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner: Any?) -> Int {
        events.append(.declare(newTypes))
        return newTypes.count
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        events.append(.set(dataType, string))
        return true
    }
}
