// Derives bulk-print eligibility from the pinned scalar classification record.

extension TerminalUnicodeClassification {
    /// True when repeated scalar printing can only stamp independent cells of the scalar's own
    /// width.
    ///
    /// Eligibility is a property of the scalar, not of its width (`research/39/D8`): a `.other`
    /// scalar without the emoji properties joins nothing before it and is joined by nothing after
    /// it except through the cell the run leaves open, and that holds for a wide scalar exactly as
    /// it holds for a narrow one. The stream cuts a run where the width changes, so one run is one
    /// width and the printer stamps it with the writer for that width.
    var isBulkPrintable: Bool {
        properties.cellWidth != .zero
            && graphemeBreakClass == .other
            && properties.isExtendedPictographic == false
            && properties.isEmojiModifier == false
            && properties.isEmojiVariationBase == false
    }
}
