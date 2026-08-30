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

    /// The writer a stretch's scalar belongs to, read once by the stream and carried from there.
    ///
    /// Bulk eligibility and width together pick the writer, and neither is answerable without the
    /// classification record -- so deriving the kind here, where the record was just read, is what
    /// keeps the printer from reading it again per scalar (`research/39/D10`). A GL byte never
    /// reaches this: the character set, not the table, decides what it prints.
    ///
    /// It takes the scalar because `.zeroWidthJoin` is not answerable from the record alone: a
    /// variation selector is classified exactly like any other zero-width scalar and is the one
    /// that can move the cell it joins.
    func stretchSegmentKind(of scalar: Unicode.Scalar) -> TerminalStretchSegmentKind {
        if isBulkPrintable {
            return properties.cellWidth == .wide ? .bulkWide : .bulkNarrow
        }
        if properties.cellWidth == .zero, Self.isVariationSelector(scalar) == false {
            return .zeroWidthJoin
        }
        return .single
    }

    /// The two selectors that ask the cluster they join to present as emoji or as text.
    ///
    /// They are the only zero-width scalars whose join can change the target cell's width, and so
    /// the only ones a segment join must refuse: every other zero-width scalar leaves the cell
    /// where it is and at the width it has, whatever the cluster's base is.
    static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0xFE0F || scalar.value == 0xFE0E
    }
}
