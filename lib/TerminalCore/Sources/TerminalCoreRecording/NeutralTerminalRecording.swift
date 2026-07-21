// Neutral terminal recording decode, validation, and replay shared by corpus
// tests and native PTY recordings without moving Foundation into TerminalCore.
import Foundation
import TerminalCore

/// Errors reject malformed or unrecognized recordings before they can become evidence.
public enum NeutralTerminalRecordingError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidHex(String)
    case invalidProvenance(String)
    case unsupportedEvent(String)
}

/// Source-aware evidence metadata lets imported fixtures and DanTerm captures share one schema.
public struct NeutralTerminalProvenance: Codable, Equatable, Sendable {
    /// Stable source discriminator used to apply the right evidence requirements.
    public let source: String
    /// Upstream source URL for imported evidence.
    public let url: String?
    /// Exact upstream revision for imported evidence.
    public let pinnedCommit: String?
    /// Upstream case name for imported evidence.
    public let upstreamCase: String?
    /// License identifier for imported evidence.
    public let license: String?
    /// Bundled license notice for imported evidence.
    public let licenseNotice: String?
    /// Deliberate semantic differences carried by imported evidence.
    public let recordedDeviations: [String]
    /// Capture owner for DanTerm-authored evidence.
    public let author: String?
    /// Behavioral test that produced a DanTerm recording.
    public let test: String?

    /// Creates DanTerm-owned provenance without pretending the capture has an upstream source.
    public static func danTerm(test: String) -> Self {
        Self(
            source: "danterm",
            url: nil,
            pinnedCommit: nil,
            upstreamCase: nil,
            license: nil,
            licenseNotice: nil,
            recordedDeviations: [],
            author: "DanTerm",
            test: test
        )
    }

    /// Creates a source record while preserving compatibility with existing neutral fixtures.
    public init(
        source: String,
        url: String? = nil,
        pinnedCommit: String? = nil,
        upstreamCase: String? = nil,
        license: String? = nil,
        licenseNotice: String? = nil,
        recordedDeviations: [String] = [],
        author: String? = nil,
        test: String? = nil
    ) {
        self.source = source
        self.url = url
        self.pinnedCommit = pinnedCommit
        self.upstreamCase = upstreamCase
        self.license = license
        self.licenseNotice = licenseNotice
        self.recordedDeviations = recordedDeviations
        self.author = author
        self.test = test
    }

    /// Rejects incomplete source claims while allowing each evidence source its own metadata.
    public func validate() throws {
        switch source {
        case "libvterm":
            guard url?.hasPrefix("https://github.com/neovim/libvterm/") == true,
                  pinnedCommit?.isEmpty == false,
                  upstreamCase?.isEmpty == false,
                  license == "MIT",
                  licenseNotice?.isEmpty == false
            else {
                throw NeutralTerminalRecordingError.invalidProvenance(source)
            }
        case "danterm":
            guard author == "DanTerm", test?.isEmpty == false else {
                throw NeutralTerminalRecordingError.invalidProvenance(source)
            }
        default:
            throw NeutralTerminalRecordingError.invalidProvenance(source)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case source, url, pinnedCommit, upstreamCase, license, licenseNotice
        case recordedDeviations, author, test
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        pinnedCommit = try values.decodeIfPresent(String.self, forKey: .pinnedCommit)
        upstreamCase = try values.decodeIfPresent(String.self, forKey: .upstreamCase)
        license = try values.decodeIfPresent(String.self, forKey: .license)
        licenseNotice = try values.decodeIfPresent(String.self, forKey: .licenseNotice)
        recordedDeviations = try values.decodeIfPresent(
            [String].self,
            forKey: .recordedDeviations
        ) ?? []
        author = try values.decodeIfPresent(String.self, forKey: .author)
        test = try values.decodeIfPresent(String.self, forKey: .test)
    }
}

/// Initial character geometry needed to replay a recording without ambient pane state.
public struct NeutralTerminalDimensions: Codable, Equatable, Sendable {
    /// Character columns in the recorded geometry.
    public let columns: Int
    /// Character rows in the recorded geometry.
    public let rows: Int

    /// Keeps the recording schema independent from either host's dimension type.
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// Describes local viewport mutations that must replay even when the child emits no bytes.
public enum NeutralTerminalViewportNavigation: Equatable, Sendable {
    case byRows(Int)
    case toTopRow(Int)
    case toBottom
}

/// Names the pointer transition recorded independently from a native event framework.
public enum NeutralTerminalMouseAction: String, Equatable, Sendable {
    case down
    case up
    case move
}

/// Preserves normalized pointer input and libvterm's button 4-7 wheel vocabulary.
public struct NeutralTerminalMouseEvent: Equatable, Sendable {
    /// Pointer transition represented by this event.
    public let action: NeutralTerminalMouseAction
    /// One-based terminal button number, absent for motion.
    public let button: Int?
    /// Zero-based pointed viewport column.
    public let column: Int
    /// Zero-based pointed viewport row.
    public let row: Int
    /// Modifier snapshot forwarded with the transition.
    public let modifiers: TerminalKeyModifiers
    /// Native click count retained for local selection granularity.
    public let clickCount: Int

    /// Creates one normalized event suitable for capture or adapted fixtures.
    public init(
        action: NeutralTerminalMouseAction,
        button: Int? = nil,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    ) {
        self.action = action
        self.button = button
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.clickCount = clickCount
    }
}

/// One owner-ordered terminal transition; checkpoints retain corpus expectation positions.
public enum NeutralTerminalRecordingEvent: Equatable, Sendable {
    case feed([UInt8])
    case input(key: TerminalInputKey, modifiers: TerminalKeyModifiers)
    case paste(String)
    case focus(Bool)
    case mouse(NeutralTerminalMouseEvent)
    case resize(columns: Int, rows: Int)
    case viewport(NeutralTerminalViewportNavigation)
    case checkpoint
}

extension NeutralTerminalRecordingEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, hex, columns, rows, action, key, scalar, modifiers, focused
        case button, column, row, clickCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        switch type {
        case "feed":
            let text = try values.decodeIfPresent(String.self, forKey: .text)
            let hex = try values.decodeIfPresent(String.self, forKey: .hex)
            guard text == nil || hex == nil else {
                throw NeutralTerminalRecordingError.invalidHex(hex ?? "")
            }
            if let text {
                self = .feed(Array(text.utf8))
            } else if let hex {
                self = .feed(try Self.decodeHex(hex))
            } else {
                throw NeutralTerminalRecordingError.invalidHex("")
            }
        case "resize":
            self = .resize(
                columns: try values.decode(Int.self, forKey: .columns),
                rows: try values.decode(Int.self, forKey: .rows)
            )
        case "input":
            self = .input(
                key: try Self.decodeKey(
                    try values.decode(String.self, forKey: .key),
                    scalar: try values.decodeIfPresent(String.self, forKey: .scalar)
                ),
                modifiers: try Self.decodeModifiers(
                    try values.decodeIfPresent([String].self, forKey: .modifiers) ?? []
                )
            )
        case "paste":
            self = .paste(try values.decode(String.self, forKey: .text))
        case "focus":
            self = .focus(try values.decode(Bool.self, forKey: .focused))
        case "mouse":
            guard let action = NeutralTerminalMouseAction(
                rawValue: try values.decode(String.self, forKey: .action)
            ) else {
                throw NeutralTerminalRecordingError.unsupportedEvent("mouse.action")
            }
            let button = try values.decodeIfPresent(Int.self, forKey: .button)
            guard action == .move ? button == nil : button.map({ (1...7).contains($0) }) == true else {
                throw NeutralTerminalRecordingError.unsupportedEvent("mouse.button")
            }
            self = .mouse(NeutralTerminalMouseEvent(
                action: action,
                button: button,
                column: try values.decode(Int.self, forKey: .column),
                row: try values.decode(Int.self, forKey: .row),
                modifiers: try Self.decodeModifiers(
                    try values.decodeIfPresent([String].self, forKey: .modifiers) ?? []
                ),
                clickCount: try values.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
            ))
        case "viewport":
            let action = try values.decode(String.self, forKey: .action)
            switch action {
            case "byRows":
                self = .viewport(.byRows(try values.decode(Int.self, forKey: .rows)))
            case "toTopRow":
                self = .viewport(.toTopRow(try values.decode(Int.self, forKey: .rows)))
            case "toBottom":
                self = .viewport(.toBottom)
            default:
                throw NeutralTerminalRecordingError.unsupportedEvent("viewport.\(action)")
            }
        case "expect":
            self = .checkpoint
        default:
            throw NeutralTerminalRecordingError.unsupportedEvent(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .feed(let bytes):
            try values.encode("feed", forKey: .type)
            try values.encode(bytes.map { String(format: "%02x", $0) }.joined(), forKey: .hex)
        case .input(let key, let modifiers):
            try values.encode("input", forKey: .type)
            let encoded = Self.encodeKey(key)
            try values.encode(encoded.name, forKey: .key)
            try values.encodeIfPresent(encoded.scalar, forKey: .scalar)
            try values.encode(Self.encodeModifiers(modifiers), forKey: .modifiers)
        case .paste(let text):
            try values.encode("paste", forKey: .type)
            try values.encode(text, forKey: .text)
        case .focus(let focused):
            try values.encode("focus", forKey: .type)
            try values.encode(focused, forKey: .focused)
        case .mouse(let mouse):
            try values.encode("mouse", forKey: .type)
            try values.encode(mouse.action.rawValue, forKey: .action)
            try values.encodeIfPresent(mouse.button, forKey: .button)
            try values.encode(mouse.column, forKey: .column)
            try values.encode(mouse.row, forKey: .row)
            try values.encode(Self.encodeModifiers(mouse.modifiers), forKey: .modifiers)
            try values.encode(mouse.clickCount, forKey: .clickCount)
        case .resize(let columns, let rows):
            try values.encode("resize", forKey: .type)
            try values.encode(columns, forKey: .columns)
            try values.encode(rows, forKey: .rows)
        case .viewport(let navigation):
            try values.encode("viewport", forKey: .type)
            switch navigation {
            case .byRows(let rows):
                try values.encode("byRows", forKey: .action)
                try values.encode(rows, forKey: .rows)
            case .toTopRow(let row):
                try values.encode("toTopRow", forKey: .action)
                try values.encode(row, forKey: .rows)
            case .toBottom:
                try values.encode("toBottom", forKey: .action)
            }
        case .checkpoint:
            try values.encode("expect", forKey: .type)
        }
    }

    private static func decodeHex(_ hex: String) throws -> [UInt8] {
        let compact = hex.filter { $0.isWhitespace == false }
        guard compact.count.isMultiple(of: 2) else {
            throw NeutralTerminalRecordingError.invalidHex(hex)
        }
        return try stride(from: 0, to: compact.count, by: 2).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            guard let byte = UInt8(compact[start..<end], radix: 16) else {
                throw NeutralTerminalRecordingError.invalidHex(hex)
            }
            return byte
        }
    }

    private static func decodeModifiers(_ names: [String]) throws -> TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        for name in names {
            switch name {
            case "shift": modifiers.insert(.shift)
            case "alt": modifiers.insert(.alt)
            case "control": modifiers.insert(.control)
            default: throw NeutralTerminalRecordingError.unsupportedEvent("input.modifier.\(name)")
            }
        }
        return modifiers
    }

    private static func encodeModifiers(_ modifiers: TerminalKeyModifiers) -> [String] {
        var names: [String] = []
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.alt) { names.append("alt") }
        if modifiers.contains(.control) { names.append("control") }
        return names
    }

    private static func decodeKey(_ name: String, scalar: String?) throws -> TerminalInputKey {
        if name == "character" {
            guard let scalar, scalar.unicodeScalars.count == 1,
                  let value = scalar.unicodeScalars.first
            else { throw NeutralTerminalRecordingError.unsupportedEvent("input.character") }
            return .character(value)
        }
        guard let key = namedKeys[name] else {
            throw NeutralTerminalRecordingError.unsupportedEvent("input.key.\(name)")
        }
        return key
    }

    private static func encodeKey(_ key: TerminalInputKey) -> (name: String, scalar: String?) {
        if case .character(let scalar) = key { return ("character", String(scalar)) }
        guard let name = namedKeys.first(where: { $0.value == key })?.key else {
            preconditionFailure("missing neutral key token")
        }
        return (name, nil)
    }

    private static let namedKeys: [String: TerminalInputKey] = [
        "return": .returnKey, "tab": .tab, "backspace": .backspace, "escape": .escape,
        "up": .up, "down": .down, "right": .right, "left": .left,
        "home": .home, "end": .end, "insert": .insert,
        "pageUp": .pageUp, "pageDown": .pageDown, "delete": .deleteForward,
        "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5, "f6": .f6,
        "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
        "keypad0": .keypad0, "keypad1": .keypad1, "keypad2": .keypad2,
        "keypad3": .keypad3, "keypad4": .keypad4, "keypad5": .keypad5,
        "keypad6": .keypad6, "keypad7": .keypad7, "keypad8": .keypad8,
        "keypad9": .keypad9, "keypadDecimal": .keypadDecimal,
        "keypadDivide": .keypadDivide, "keypadMultiply": .keypadMultiply,
        "keypadSubtract": .keypadSubtract, "keypadAdd": .keypadAdd,
        "keypadEnter": .keypadEnter, "keypadEqual": .keypadEqual,
    ]
}

/// Replays one neutral mouse event through the shared policy and applies only local selection.
public func applyNeutralTerminalMouse(
    _ mouse: NeutralTerminalMouseEvent,
    terminal: inout Terminal,
    interactionState: inout TerminalInteractionState
) -> [UInt8] {
    if let direction = neutralWheelDirection(for: mouse) {
        guard mouse.action == .down else { return [] }
        return decideTerminalMouseWheelReport(
            direction,
            column: mouse.column,
            row: mouse.row,
            modifiers: mouse.modifiers,
            terminal: terminal,
            state: &interactionState
        )
    }

    guard let event = neutralPointerEvent(for: mouse) else { return [] }
    let decision = decideTerminalPointer(event, terminal: terminal, state: &interactionState)
    switch decision.selectionMutation {
    case .clear:
        terminal.clearSelection()
    case .set(let range):
        terminal.setSelection(range)
    case nil:
        break
    }
    return decision.inputBytes
}

private func neutralPointerEvent(for mouse: NeutralTerminalMouseEvent) -> TerminalPointerEvent? {
    let button = mouse.button.flatMap { TerminalMouseButton(rawValue: $0 - 1) }
    switch mouse.action {
    case .down:
        guard let button else { return nil }
        return .down(
            button,
            column: mouse.column,
            row: mouse.row,
            modifiers: mouse.modifiers,
            clickCount: mouse.clickCount
        )
    case .up:
        guard let button else { return nil }
        return .up(
            button,
            column: mouse.column,
            row: mouse.row,
            modifiers: mouse.modifiers
        )
    case .move:
        return .move(column: mouse.column, row: mouse.row, modifiers: mouse.modifiers)
    }
}

private func neutralWheelDirection(
    for mouse: NeutralTerminalMouseEvent
) -> TerminalMouseWheelDirection? {
    guard let button = mouse.button else { return nil }
    return TerminalMouseWheelDirection(rawValue: button + 60)
}

/// Complete neutral evidence that can be serialized by a PTY test and replayed by core tests.
public struct NeutralTerminalRecording: Codable, Equatable, Sendable {
    /// Schema revision, currently fixed at one.
    public let version: Int
    /// Source-specific evidence metadata validated before replay.
    public let provenance: NeutralTerminalProvenance
    /// Geometry installed before the first recorded event.
    public let initial: NeutralTerminalDimensions
    /// Owner-ordered terminal mutations and optional corpus checkpoints.
    public let events: [NeutralTerminalRecordingEvent]

    /// Creates a complete recording that can cross package test boundaries.
    public init(
        version: Int = 1,
        provenance: NeutralTerminalProvenance,
        initial: NeutralTerminalDimensions,
        events: [NeutralTerminalRecordingEvent]
    ) {
        self.version = version
        self.provenance = provenance
        self.initial = initial
        self.events = events
    }

    /// Replays through TerminalCore and exposes each ordered checkpoint to corpus assertions.
    public func replay(
        inspect: (_ eventIndex: Int, _ terminal: Terminal) throws -> Void = { _, _ in }
    ) throws -> Terminal {
        guard version == 1,
              let initialTerminal = Terminal(columns: initial.columns, rows: initial.rows)
        else {
            throw NeutralTerminalRecordingError.invalidDimensions
        }
        try provenance.validate()
        var terminal = initialTerminal
        var interactionState = TerminalInteractionState()
        for (index, event) in events.enumerated() {
            switch event {
            case .feed(let bytes):
                terminal.feed(bytes)
                _ = terminal.drainReplyBytes()
            case .input, .paste, .focus:
                break
            case .mouse(let mouse):
                _ = applyNeutralTerminalMouse(
                    mouse,
                    terminal: &terminal,
                    interactionState: &interactionState
                )
            case .resize(let columns, let rows):
                guard columns >= 2, rows >= 1 else {
                    throw NeutralTerminalRecordingError.invalidDimensions
                }
                terminal.resize(columns: columns, rows: rows)
            case .viewport(let navigation):
                switch navigation {
                case .byRows(let rows): terminal.scroll(byRows: rows)
                case .toTopRow(let row): terminal.scroll(toTopRow: row)
                case .toBottom: terminal.scrollToBottom()
                }
            case .checkpoint:
                break
            }
            try inspect(index, terminal)
        }
        return terminal
    }
}
