// Neutral terminal recording decode, validation, and replay shared by corpus
// tests and native PTY recordings without moving Foundation into TerminalCore.
import Foundation
import TerminalCore

/// Errors reject malformed or unrecognized recordings before they can become evidence.
public enum NeutralTerminalRecordingError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidBase64(String)
    case invalidEvent(String)
    case invalidProvenance(String)
    case unsupportedEvent(String)
    /// Carries the schema revision this build cannot read, so a future or corrupt `version`
    /// is never mistaken for a geometry failure.
    case unsupportedVersion(Int)
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

    /// Marks an unscrubbed live-pane dump as replayable evidence that is not fixture-ready.
    public static func liveCapture() -> Self {
        Self(
            source: "danterm-live-capture",
            recordedDeviations: [],
            author: "DanTerm",
            test: "live-pane-tape"
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
        case "alacritty":
            guard url?.hasPrefix("https://github.com/alacritty/alacritty/") == true,
                  pinnedCommit?.isEmpty == false,
                  upstreamCase?.isEmpty == false,
                  license == "Apache-2.0",
                  licenseNotice?.isEmpty == false
            else {
                throw NeutralTerminalRecordingError.invalidProvenance(source)
            }
        case "windows-terminal":
            guard url?.hasPrefix("https://github.com/microsoft/terminal/") == true,
                  pinnedCommit?.isEmpty == false,
                  upstreamCase?.isEmpty == false,
                  license == "MIT",
                  licenseNotice?.isEmpty == false
            else {
                throw NeutralTerminalRecordingError.invalidProvenance(source)
            }
        case "danterm", "danterm-live-capture":
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

/// A pane's replicated geometry as one fact: the grid, plus whether that grid is pinned.
///
/// Pinned means the grid is an explicit override; unpinned means it is derived from the
/// pane's rectangle. Recording carries the pair together so no observer can hold half of a
/// transition -- a grid without its pinnedness, or the reverse. It is deliberately separate
/// from `NeutralTerminalDimensions`, which is replay geometry and has no use for the bit.
public struct NeutralTerminalGeometry: Equatable, Sendable {
    /// Character columns in the applied grid.
    public let columns: Int
    /// Character rows in the applied grid.
    public let rows: Int
    /// Whether the grid is an override rather than a projection of the pane's rectangle.
    public let pinned: Bool

    /// Keeps stream geometry independent from either host's dimension type.
    public init(columns: Int, rows: Int, pinned: Bool) {
        self.columns = columns
        self.rows = rows
        self.pinned = pinned
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
    /// Pointer position inside the pointed cell as a `0...1` fraction of its width, which
    /// character-granularity selection resolves a boundary from. Recordings captured before
    /// this was carried decode to `0`, the cell's leading edge.
    public let offsetX: Double
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
        offsetX: Double = 0,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    ) {
        self.action = action
        self.button = button
        self.column = column
        self.row = row
        self.offsetX = offsetX
        self.modifiers = modifiers
        self.clickCount = clickCount
    }
}

/// One owner-ordered terminal transition; checkpoints retain corpus expectation positions.
public enum NeutralTerminalRecordingEvent: Equatable, Sendable {
    case feed([UInt8])
    /// Bytes that crossed the pane boundary toward the child, recorded as transmitted. Replay
    /// ignores them: only `feed` drives the terminal, and echoing these would double the input.
    case write([UInt8])
    case input(key: TerminalInputKey, modifiers: TerminalKeyModifiers)
    case paste(String)
    case focus(Bool)
    case mouse(NeutralTerminalMouseEvent)
    /// One applied geometry fact stated whole: the grid, and whether that grid is pinned.
    /// Pinned means the grid is an explicit override rather than a projection of the pane's
    /// rectangle. The bit reaches no terminal -- replay ignores it -- so a pinnedness-only
    /// transition is invisible to the child and to cell content. It exists so a replica can
    /// tell which writer produced the current grid without comparing grids.
    case resize(columns: Int, rows: Int, pinned: Bool)
    case viewport(NeutralTerminalViewportNavigation)
    case checkpoint
}

extension NeutralTerminalRecordingEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, base64, columns, rows, pinned, action, key, scalar, modifiers, focused
        case button, column, row, offsetX, clickCount, expect, elapsedNanoseconds
        case originElapsedNanoseconds
    }

    public init(from decoder: any Decoder) throws {
        let dynamicValues = try decoder.container(keyedBy: EventCodingKey.self)
        let keys = Set(dynamicValues.allKeys.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        if values.contains(.elapsedNanoseconds) {
            _ = try values.decode(UInt64.self, forKey: .elapsedNanoseconds)
        }
        switch type {
        case "feed":
            self = .feed(try Self.decodeBytes(
                keys,
                values: values,
                optional: ["elapsedNanoseconds"],
                type: type
            ))
        case "write":
            // Bytes travelling toward the child are the only ones with an origin earlier than
            // their own transfer, so this second inert stamp is admitted here and nowhere else.
            if values.contains(.originElapsedNanoseconds) {
                _ = try values.decode(UInt64.self, forKey: .originElapsedNanoseconds)
            }
            self = .write(try Self.decodeBytes(
                keys,
                values: values,
                optional: ["elapsedNanoseconds", "originElapsedNanoseconds"],
                type: type
            ))
        case "resize":
            // `pinned` is optional on the way in so the stored fixture corpus, recorded
            // before pinnedness existed, still decodes; it is always written on the way
            // out. A peer on the other side of the shape change never reaches this decode
            // -- the handshake's protocol number refuses it first.
            try Self.validateKeys(
                keys,
                required: ["type", "columns", "rows"],
                optional: ["pinned", "elapsedNanoseconds"],
                type: type
            )
            self = .resize(
                columns: try values.decode(Int.self, forKey: .columns),
                rows: try values.decode(Int.self, forKey: .rows),
                pinned: try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            )
        case "input":
            let key = try values.decode(String.self, forKey: .key)
            try Self.validateKeys(
                keys,
                required: key == "character" ? ["type", "key", "scalar"] : ["type", "key"],
                optional: ["modifiers", "elapsedNanoseconds"],
                type: type
            )
            self = .input(
                key: try Self.decodeKey(
                    key,
                    scalar: try values.decodeIfPresent(String.self, forKey: .scalar)
                ),
                modifiers: try Self.decodeModifiers(
                    try values.decodeIfPresent([String].self, forKey: .modifiers) ?? []
                )
            )
        case "paste":
            try Self.validateKeys(
                keys,
                required: ["type", "text"],
                optional: ["elapsedNanoseconds"],
                type: type
            )
            self = .paste(try values.decode(String.self, forKey: .text))
        case "focus":
            try Self.validateKeys(
                keys,
                required: ["type", "focused"],
                optional: ["elapsedNanoseconds"],
                type: type
            )
            self = .focus(try values.decode(Bool.self, forKey: .focused))
        case "mouse":
            try Self.validateKeys(
                keys,
                required: ["type", "action", "column", "row"],
                optional: ["button", "offsetX", "modifiers", "clickCount", "elapsedNanoseconds"],
                type: type
            )
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
                offsetX: try values.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0,
                modifiers: try Self.decodeModifiers(
                    try values.decodeIfPresent([String].self, forKey: .modifiers) ?? []
                ),
                clickCount: try values.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
            ))
        case "viewport":
            let action = try values.decode(String.self, forKey: .action)
            switch action {
            case "byRows":
                try Self.validateKeys(
                    keys,
                    required: ["type", "action", "rows"],
                    optional: ["elapsedNanoseconds"],
                    type: type
                )
                self = .viewport(.byRows(try values.decode(Int.self, forKey: .rows)))
            case "toTopRow":
                try Self.validateKeys(
                    keys,
                    required: ["type", "action", "rows"],
                    optional: ["elapsedNanoseconds"],
                    type: type
                )
                self = .viewport(.toTopRow(try values.decode(Int.self, forKey: .rows)))
            case "toBottom":
                try Self.validateKeys(
                    keys,
                    required: ["type", "action"],
                    optional: ["elapsedNanoseconds"],
                    type: type
                )
                self = .viewport(.toBottom)
            default:
                throw NeutralTerminalRecordingError.unsupportedEvent("viewport.\(action)")
            }
        case "expect":
            try Self.validateKeys(
                keys,
                required: ["type"],
                optional: ["expect", "elapsedNanoseconds"],
                type: type
            )
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
            try values.encode(Data(bytes).base64EncodedString(), forKey: .base64)
        case .write(let bytes):
            try values.encode("write", forKey: .type)
            try values.encode(Data(bytes).base64EncodedString(), forKey: .base64)
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
            try values.encode(mouse.offsetX, forKey: .offsetX)
            try values.encode(Self.encodeModifiers(mouse.modifiers), forKey: .modifiers)
            try values.encode(mouse.clickCount, forKey: .clickCount)
        case .resize(let columns, let rows, let pinned):
            try values.encode("resize", forKey: .type)
            try values.encode(columns, forKey: .columns)
            try values.encode(rows, forKey: .rows)
            try values.encode(pinned, forKey: .pinned)
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

    /// Decodes the one byte payload both directions share, in either encoding, so a readable
    /// text event and a binary base64 one stay interchangeable for every byte transfer.
    private static func decodeBytes(
        _ keys: Set<String>,
        values: KeyedDecodingContainer<CodingKeys>,
        optional: Set<String>,
        type: String
    ) throws -> [UInt8] {
        let encodings = Set(["base64", "text"]).intersection(keys)
        guard encodings.count == 1, let encoding = encodings.first else {
            throw NeutralTerminalRecordingError.invalidEvent(type)
        }
        try validateKeys(keys, required: ["type", encoding], optional: optional, type: type)
        if encoding == "text" {
            return Array(try values.decode(String.self, forKey: .text).utf8)
        }
        let base64 = try values.decode(String.self, forKey: .base64)
        guard let data = Data(base64Encoded: base64) else {
            throw NeutralTerminalRecordingError.invalidBase64(base64)
        }
        return Array(data)
    }

    private static func validateKeys(
        _ keys: Set<String>,
        required: Set<String>,
        optional: Set<String>,
        type: String
    ) throws {
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw NeutralTerminalRecordingError.invalidEvent(type)
        }
    }

    private static func decodeModifiers(_ names: [String]) throws -> TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        for name in names {
            switch name {
            case "shift": modifiers.insert(.shift)
            case "alt": modifiers.insert(.alt)
            case "control": modifiers.insert(.control)
            case "command": modifiers.insert(.command)
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
        if modifiers.contains(.command) { names.append("command") }
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

/// Exposes every object key so event decoding can reject fields unknown to its schema.
private struct EventCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
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
        terminal.setSelection(
            range,
            granularity: decision.selectionGranularity ?? .character
        )
    case nil:
        break
    }
    switch decision.hoverMutation {
    case .clear:
        terminal.clearHoveredLink()
    case .set(let link):
        terminal.setHoveredLink(link)
    case nil:
        break
    }
    switch decision.armMutation {
    case .clear:
        terminal.clearArmedLink()
    case .set(let link):
        _ = terminal.setArmedLink(link)
    case nil:
        break
    }
    return decision.inputBytes
}

private func neutralPointerEvent(for mouse: NeutralTerminalMouseEvent) -> TerminalPointerEvent? {
    let button = mouse.button.flatMap { TerminalMouseButton(rawValue: $0 - 1) }
    let cell = TerminalViewportCell(
        column: mouse.column,
        row: mouse.row,
        offsetX: mouse.offsetX
    )
    switch mouse.action {
    case .down:
        guard let button else { return nil }
        return .down(
            button,
            cell: cell,
            modifiers: mouse.modifiers,
            clickCount: mouse.clickCount
        )
    case .up:
        guard let button else { return nil }
        return .up(button, cell: cell, modifiers: mouse.modifiers)
    case .move:
        return .move(cell: cell, modifiers: mouse.modifiers)
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
    ///
    /// `machineHostname` is the machine identity the replay terminal is configured with. It
    /// stays nil for neutral fixtures, which carry no host-specific bytes; a caller comparing
    /// a replay against a live pane's snapshot must pass the identity that pane was built
    /// with, or the two terminals differ on configuration alone.
    public func replay(
        machineHostname: String? = nil,
        defaultColors: TerminalDefaultColors = .baked,
        inspect: (_ eventIndex: Int, _ terminal: Terminal) throws -> Void = { _, _ in }
    ) throws -> Terminal {
        guard version == 1 else {
            throw NeutralTerminalRecordingError.unsupportedVersion(version)
        }
        guard let initialTerminal = Terminal(
            columns: initial.columns,
            rows: initial.rows,
            machineHostname: machineHostname,
            defaultColors: defaultColors
        ) else {
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
                _ = terminal.drainPendingClipboardWrite()
            case .write, .input, .paste, .focus:
                break
            case .mouse(let mouse):
                _ = applyNeutralTerminalMouse(
                    mouse,
                    terminal: &terminal,
                    interactionState: &interactionState
                )
            case .resize(let columns, let rows, _):
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
