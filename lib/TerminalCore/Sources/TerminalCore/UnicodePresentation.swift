// Derives the text-versus-emoji presentation of a cell from the pinned scalar table, so
// the renderer can state a decision Unicode already made instead of leaving it to the
// host's font machinery.
//
// Only the decision lives here. Where the selector is appended, and what CoreText does
// with it, belongs to the render fallback in `TerminalRenderExecution`.

/// The form Unicode gives a bare scalar that has both a text and an emoji form.
///
/// Only variation bases have one: every other scalar has a single form, and there is
/// nothing for a selector to choose between.
enum TerminalDefaultPresentation: Equatable, Sendable {
    case text
    case emoji
}

/// Reports the form a bare scalar takes by Unicode's own default, or nil when the scalar
/// is not an emoji variation base and so has no second form to state.
func terminalDefaultPresentation(for scalar: Unicode.Scalar) -> TerminalDefaultPresentation? {
    let properties = terminalUnicodeProperties(for: scalar)
    guard properties.isEmojiVariationBase else { return nil }
    return properties.hasEmojiPresentation ? .emoji : .text
}

/// The variation selector a renderer appends to a cell's scalars to state the
/// presentation Unicode already defines, or nil when the cell is drawn as the stream
/// wrote it.
///
/// Public because the render fallback is the caller and lives in another module. Only a
/// single bare default-text variation base is transformed: a multi-scalar cell is a
/// cluster the terminal already assembled, a cell carrying a selector stated its own
/// presentation, and a default-emoji scalar was given a wide cell to be drawn as an
/// emoji in.
public func terminalPresentationSelectorToAppend(
    for scalars: some Collection<Unicode.Scalar>
) -> Unicode.Scalar? {
    guard scalars.count == 1, let scalar = scalars.first else { return nil }
    guard terminalDefaultPresentation(for: scalar) == .text else { return nil }
    return textPresentationSelector
}

/// U+FE0E, which asks for the text form. It is a preference and not a restriction: a
/// scalar no text face covers still falls through to a face that can draw it.
private let textPresentationSelector: Unicode.Scalar = "\u{FE0E}"
