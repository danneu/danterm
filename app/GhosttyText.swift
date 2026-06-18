// Shared helpers for length-bounded text buffers returned by libghostty. Keep
// ownership with the caller: this file decodes `ghostty_text_s` but never frees it.
import GhosttyKit

/// Decode a libghostty text buffer using `text_len`, so embedded NUL bytes do
/// not truncate the result. Callers still own the matching free.
func decodeGhosttyText(_ text: ghostty_text_s) -> String? {
    guard text.text_len > 0 else { return "" }
    guard let ptr = text.text else { return nil }
    let len = Int(text.text_len)
    return ptr.withMemoryRebound(to: UInt8.self, capacity: len) { reboundPtr in
        String(bytes: UnsafeBufferPointer(start: reboundPtr, count: len), encoding: .utf8)
    }
}
