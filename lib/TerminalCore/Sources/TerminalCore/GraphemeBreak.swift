// Pure streaming Unicode grapheme segmentation over generated, pinned properties.

/// Folded UAX #29 classes keep pairwise segmentation independent of Foundation Unicode data.
enum GraphemeBreakClass: UInt8, Equatable, Sendable {
    case other
    case control
    case prepend
    case cr
    case lf
    case regionalIndicator
    case spacingMark
    case l
    case v
    case t
    case lv
    case lvt
    case zwj
    case zwnj
    case extendedPictographic
    case indicConjunctBreakExtend
    case indicConjunctBreakLinker
    case indicConjunctBreakConsonant
}

/// Carries only the look-behind that UAX #29 needs across adjacent scalar pairs and feed chunks.
enum GraphemeBreakState: Equatable, Sendable {
    case initial
    case regionalIndicator
    case extendedPictographic
    case indicConjunctBreakConsonant
    case indicConjunctBreakLinker

    init() {
        self = .initial
    }
}

/// Decides one streaming grapheme boundary while advancing the caller-owned look-behind state.
func graphemeBreak(
    between previous: Unicode.Scalar,
    and current: Unicode.Scalar,
    state: inout GraphemeBreakState
) -> Bool {
    state.shouldBreak(
        between: graphemeBreakClass(for: previous),
        and: graphemeBreakClass(for: current)
    )
}

private extension GraphemeBreakState {
    mutating func shouldBreak(
        between previous: GraphemeBreakClass,
        and current: GraphemeBreakClass
    ) -> Bool {
        normalize(for: previous, and: current)

        // GB3-GB5: controls are isolated except for CR x LF.
        if previous == .cr && current == .lf { return false }
        if previous.isControl || current.isControl { return true }

        // GB6-GB8: Hangul syllable sequences.
        if previous == .l && [.l, .v, .lv, .lvt].contains(current) { return false }
        if [.lv, .v].contains(previous) && [.v, .t].contains(current) { return false }
        if [.lvt, .t].contains(previous) && current == .t { return false }

        // GB9a-GB9b. GB9 follows the stateful rules below.
        if current == .spacingMark { return false }
        if previous == .prepend { return false }

        // GB9c: Indic consonant [Extend Linker]* Linker [Extend Linker]* x consonant.
        if previous == .indicConjunctBreakConsonant {
            if current.isIndicExtend {
                self = .indicConjunctBreakConsonant
                return false
            }
            if current == .indicConjunctBreakLinker {
                self = .indicConjunctBreakLinker
                return false
            }
        } else if self == .indicConjunctBreakConsonant {
            if current == .indicConjunctBreakLinker {
                self = .indicConjunctBreakLinker
                return false
            }
            if current.isIndicExtend { return false }
            self = .initial
        } else if self == .indicConjunctBreakLinker {
            if current == .indicConjunctBreakLinker || current.isIndicExtend {
                return false
            }
            if current == .indicConjunctBreakConsonant {
                self = .initial
                return false
            }
            self = .initial
        }

        // GB11: Extended_Pictographic Extend* ZWJ x Extended_Pictographic.
        if previous == .extendedPictographic {
            if current.isExtend || current == .zwj {
                self = .extendedPictographic
                return false
            }
        } else if self == .extendedPictographic {
            if previous.isExtend && (current.isExtend || current == .zwj) {
                return false
            }
            if previous == .zwj && current == .extendedPictographic {
                self = .initial
                return false
            }
            self = .initial
        }

        // GB12-GB13: pair Regional Indicators from the start of each run.
        if previous == .regionalIndicator && current == .regionalIndicator {
            if self == .initial {
                self = .regionalIndicator
                return false
            }
            self = .initial
            return true
        }

        // GB9 and GB999.
        if current.isExtend || current == .zwj { return false }
        return true
    }

    mutating func normalize(
        for previous: GraphemeBreakClass,
        and current: GraphemeBreakClass
    ) {
        switch self {
        case .regionalIndicator:
            if previous != .regionalIndicator || current != .regionalIndicator {
                self = .initial
            }
        case .extendedPictographic:
            if previous.isEmojiSequenceClass == false || current.isEmojiSequenceClass == false {
                self = .initial
            }
        case .indicConjunctBreakConsonant, .indicConjunctBreakLinker:
            if previous.isIndicSequenceClass == false || current.isIndicSequenceClass == false {
                self = .initial
            }
        case .initial:
            break
        }
    }
}

private extension GraphemeBreakClass {
    var isControl: Bool {
        self == .control || self == .cr || self == .lf
    }

    var isExtend: Bool {
        self == .zwnj
            || self == .indicConjunctBreakExtend
            || self == .indicConjunctBreakLinker
    }

    var isIndicExtend: Bool {
        self == .indicConjunctBreakExtend || self == .zwj
    }

    var isEmojiSequenceClass: Bool {
        isExtend || self == .zwj || self == .extendedPictographic
    }

    var isIndicSequenceClass: Bool {
        self == .indicConjunctBreakConsonant
            || self == .indicConjunctBreakLinker
            || self == .indicConjunctBreakExtend
            || self == .zwj
    }
}
