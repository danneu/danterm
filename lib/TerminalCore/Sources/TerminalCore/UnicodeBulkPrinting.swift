// Derives bulk-print eligibility from the pinned scalar classification record.

extension TerminalUnicodeClassification {
    /// True when repeated scalar printing can only stamp independent narrow cells.
    var isBulkPrintable: Bool {
        properties.cellWidth == .narrow
            && graphemeBreakClass == .other
            && properties.isExtendedPictographic == false
            && properties.isEmojiModifier == false
            && properties.isEmojiVariationBase == false
    }
}
