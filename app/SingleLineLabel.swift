// The label every fixed-height row uses, and the one-line rule it enforces.
// Nothing about a particular surface belongs here: a caller picks the truncation
// style and the font, and this file decides what a one-line label does with a
// string that is not one line.
import Cocoa

/// A label that lays out on exactly one line, whatever string it is handed.
///
/// AppKit cannot be configured into this. `usesSingleLineMode`,
/// `maximumNumberOfLines`, `wraps`, and `lineBreakMode` govern *soft* wrapping:
/// they stop a too-wide string from flowing onto a second line. None of them
/// affect a hard line break -- an `NSTextField` handed "a\nb" lays out two lines
/// and grows to 32 pt whatever those properties say, which in a 40 pt sidebar row
/// pushes the subtitle and the pane strip out of the row. So the value has to be
/// flattened on its way in, and the row's own label is the last place that can
/// still do it.
///
/// This is the second of the two guards, independent of the first: `DisplayLine`
/// keeps a multi-line value from ever reaching a view, and this keeps the row
/// intact if one ever does. Both run the same normalizer, so there is one rule
/// about what a display line may contain, applied at two boundaries -- the same
/// shape `String.singleLineName` already has for name admission.
class SingleLineLabel: NSTextField {
    /// A configured one-line label. Use this rather than the inherited
    /// `init(labelWithString:)`, which leaves the soft-wrap half unset.
    static func make(truncating mode: NSLineBreakMode = .byTruncatingTail) -> Self {
        let label = Self(labelWithString: "")
        label.lineBreakMode = mode
        label.maximumNumberOfLines = 1
        label.cell?.lineBreakMode = mode
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.usesSingleLineMode = true
        return label
    }

    override var stringValue: String {
        get { super.stringValue }
        set { super.stringValue = DisplayLine(newValue).text }
    }
}
