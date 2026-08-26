// The one CSI spelling of each setting DanTerm both replays and reports.
//
// Two consumers need the same bytes for the same state: state synchronization replays a setting
// into a fresh terminal, and DECRQSS reports it to a program that wants to replay it itself.
// Holding the spelling once is what makes the report and the replay the same sequence by
// construction rather than by two authors agreeing. Settings with only one consumer -- modes,
// charsets, cursor position -- stay with their own encoder.
//
// Every value here is a DECRQSS *status string*: the sequence body without its CSI introducer,
// which is the exact form a reply carries.

/// Renders each reportable setting as the CSI body that re-establishes it.
enum TerminalSettingReport {
    /// SGR. Always led by `0`, so the rendition is absolute rather than a delta on the pen.
    ///
    /// Protection is deliberately absent: SGR 0 no longer clears DECSCA, so the two settings are
    /// independent and each states itself.
    static func selectGraphicRendition(_ style: TerminalStyle) -> String {
        var parameters = ["0"]
        if style.bold { parameters.append("1") }
        if style.dim { parameters.append("2") }
        if style.italic { parameters.append("3") }
        switch style.underline {
        case .none: break
        case .single: parameters.append("4")
        case .double: parameters.append("4:2")
        case .curly: parameters.append("4:3")
        case .dotted: parameters.append("4:4")
        case .dashed: parameters.append("4:5")
        }
        if style.reverse { parameters.append("7") }
        if style.hidden { parameters.append("8") }
        if style.strikethrough { parameters.append("9") }
        appendColor(style.foreground, selector: 38, to: &parameters)
        appendColor(style.background, selector: 48, to: &parameters)
        appendColor(style.underlineColor, selector: 58, to: &parameters)
        return parameters.joined(separator: ";") + "m"
    }

    /// DECSCA: whether the pen arms protection against the selective erases.
    static func selectCharacterProtection(_ protected: Bool) -> String {
        "\(protected ? 1 : 0)\"q"
    }

    /// DECSCUSR: cursor shape and blink as the one parameter that carries both.
    static func setCursorStyle(shape: TerminalCursorShape, blinking: Bool) -> String {
        let parameter = switch (shape, blinking) {
        case (.block, true): 1
        case (.block, false): 2
        case (.underline, true): 3
        case (.underline, false): 4
        case (.bar, true): 5
        case (.bar, false): 6
        }
        return "\(parameter) q"
    }

    /// DECSTBM: the active scroll region as one-based inclusive rows.
    ///
    /// A terminal with no region set reports the whole screen, which is the same region and the
    /// same sequence the screen would take to re-establish it.
    static func setTopAndBottomMargins(_ region: Range<Int>) -> String {
        "\(region.lowerBound + 1);\(region.upperBound)r"
    }

    private static func appendColor(
        _ color: TerminalColor,
        selector: Int,
        to parameters: inout [String]
    ) {
        switch color {
        case .default:
            if selector == 58 { parameters.append("59") }
        case .indexed(let index):
            parameters.append(contentsOf: [String(selector), "5", String(index)])
        case .rgb(let red, let green, let blue):
            parameters.append(contentsOf: [
                String(selector), "2", String(red), String(green), String(blue),
            ])
        }
    }
}
