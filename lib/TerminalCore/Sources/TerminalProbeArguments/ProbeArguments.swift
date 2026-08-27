// The one flag parser behind every probe and benchmark CLI in this package.
//
// It exists because each executable hand-rolled its own walk over `CommandLine.arguments`, and
// two of them -- the memory and the occupancy probe -- shared a helper that could not fail. A
// value it could not parse, a flag written without its value, and a misspelled flag name all
// resolved to the declared default, so the probe measured a geometry the recipe never asked for
// and printed a header that looked deliberate. `--iterations 0` was worse: it exited 0 over a
// table of zeroes. That is the failure `agent-docs/measurement-discipline.md` opens with, and no
// suite could reach it, because the parse lived in `main.swift` where nothing can import it.
//
// So the parse is pure and returns a `Result`. Every rejection is a value a test asserts on, and
// only `main.swift` turns one into `exit(2)`. After it returns success, "a flag was given and
// ignored" is not representable: every word of the argument list has been consumed into a
// validated value, or the parse has failed.
//
// What does not belong here is anything a probe knows about its own subject -- whether two
// widths differ enough to measure a reflow, whether a payload name exists. Those are checked by
// the caller against its own support module. This file knows only names, kinds, and ranges.

/// A flag that takes a whole number, with the range outside which the probe cannot measure.
///
/// The range lives with the declaration rather than at the use site so that a probe cannot
/// forget it: `minimum` is the smallest value the measurement is defined for, not the smallest
/// the type can hold.
public struct IntegerFlag: Sendable, Equatable {
    public let name: String
    public let defaultValue: Int
    public let minimum: Int
    public let maximum: Int?

    public init(_ name: String, default defaultValue: Int, minimum: Int, maximum: Int? = nil) {
        self.name = name
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// How many times a probe measures something, which is never zero.
///
/// Exists so the parse's floor of 1 reaches the measurement as a type. A probe that took a
/// plain `Int` had the floor checked at the command line and nowhere else, so every other
/// caller -- a test, a benchmark arm, a future recipe -- could still ask for zero iterations
/// and get a report of statistics over nothing. With this value in the signature, the summary
/// types below it can hold their first measurement as a stored field and delete their
/// empty-list fallbacks.
public struct PositiveCount: Sendable, Equatable, Hashable {
    public let value: Int

    public init?(_ value: Int) {
        guard value >= 1 else { return nil }
        self.value = value
    }

    /// For a count written as a literal in source -- a recipe's declared sample count, a flag's
    /// declared default. Traps rather than failing, because a literal below 1 is a mistake in
    /// the source and not a runtime condition; anything derived from input takes `init?`.
    public static func declared(_ value: Int) -> PositiveCount {
        guard let count = PositiveCount(value) else {
            preconditionFailure("a declared measurement count must be at least 1, not \(value)")
        }
        return count
    }
}

/// A flag that names how many measurements to take, parsed as a `PositiveCount`.
///
/// A separate kind from `IntegerFlag` rather than a minimum of 1 written at each declaration:
/// the floor is the whole point of the flag, so it belongs in the type the parse returns and
/// not in a number a later edit can lower.
public struct CountFlag: Sendable, Equatable {
    public let name: String
    public let defaultValue: PositiveCount
    public let maximum: Int?

    public init(_ name: String, default defaultValue: PositiveCount, maximum: Int? = nil) {
        self.name = name
        self.defaultValue = defaultValue
        self.maximum = maximum
    }
}

/// A flag that is present or absent and takes no value.
public struct SwitchFlag: Sendable, Equatable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

/// A flag that takes free text, optionally restricted to a closed set of names.
///
/// `defaultValue` is optional because absence is meaningful for some of these: the memory
/// probe's `--payload` unset means "run the whole matrix", which no name can spell.
public struct TextFlag: Sendable, Equatable {
    public let name: String
    public let defaultValue: String?
    public let allowed: [String]?

    public init(_ name: String, default defaultValue: String? = nil, allowed: [String]? = nil) {
        self.name = name
        self.defaultValue = defaultValue
        self.allowed = allowed
    }
}

/// One entry in a command's declared flag list.
public enum ProbeFlag: Sendable, Equatable {
    case integer(IntegerFlag)
    case count(CountFlag)
    case text(TextFlag)
    case toggle(SwitchFlag)

    var name: String {
        switch self {
        case .integer(let flag): flag.name
        case .count(let flag): flag.name
        case .text(let flag): flag.name
        case .toggle(let flag): flag.name
        }
    }
}

/// The full flag surface of one executable: what it accepts, and the line it prints when it
/// refuses. Declaring the whole surface is what lets the parse reject an unknown flag, which is
/// the half of the check a per-flag lookup can never do.
public struct ProbeCommand: Sendable {
    public let usage: String
    public let flags: [ProbeFlag]

    public init(usage: String, flags: [ProbeFlag]) {
        self.usage = usage
        self.flags = flags
    }

    /// Consumes the whole argument list, or names the first word it refuses.
    ///
    /// Pass `CommandLine.arguments.dropFirst()`; the executable path is not a flag.
    public func parse(_ arguments: some Sequence<String>) -> Result<ProbeArguments, ProbeArgumentError> {
        var integers: [String: Int] = [:]
        var counts: [String: PositiveCount] = [:]
        var texts: [String: String] = [:]
        var toggles: Set<String> = []
        var seen: Set<String> = []
        let words = Array(arguments)
        var index = 0

        func refuse(_ name: String, _ reason: ProbeArgumentError.Reason) -> Result<ProbeArguments, ProbeArgumentError> {
            .failure(ProbeArgumentError(flag: name, reason: reason, usage: usage))
        }

        while index < words.count {
            let word = words[index]
            guard let flag = flags.first(where: { $0.name == word }) else {
                return refuse(word, .unknownFlag)
            }
            guard seen.insert(word).inserted else {
                return refuse(word, .repeatedFlag)
            }
            switch flag {
            case .toggle:
                toggles.insert(word)
                index += 1
            case .integer(let spec):
                guard index + 1 < words.count else { return refuse(word, .missingValue) }
                let raw = words[index + 1]
                guard let value = Int(raw) else { return refuse(word, .notAWholeNumber(raw)) }
                guard value >= spec.minimum else {
                    return refuse(word, .belowMinimum(value: value, minimum: spec.minimum))
                }
                if let maximum = spec.maximum, value > maximum {
                    return refuse(word, .aboveMaximum(value: value, maximum: maximum))
                }
                integers[word] = value
                index += 2
            case .count(let spec):
                guard index + 1 < words.count else { return refuse(word, .missingValue) }
                let raw = words[index + 1]
                guard let value = Int(raw) else { return refuse(word, .notAWholeNumber(raw)) }
                guard let count = PositiveCount(value) else {
                    return refuse(word, .belowMinimum(value: value, minimum: 1))
                }
                if let maximum = spec.maximum, value > maximum {
                    return refuse(word, .aboveMaximum(value: value, maximum: maximum))
                }
                counts[word] = count
                index += 2
            case .text(let spec):
                guard index + 1 < words.count else { return refuse(word, .missingValue) }
                let raw = words[index + 1]
                if let allowed = spec.allowed, allowed.contains(raw) == false {
                    return refuse(word, .notAllowed(value: raw, allowed: allowed))
                }
                texts[word] = raw
                index += 2
            }
        }

        return .success(
            ProbeArguments(integers: integers, counts: counts, texts: texts, toggles: toggles)
        )
    }
}

/// The validated result of one parse.
///
/// Read through the same flag values the command was declared with, so a use site cannot name a
/// flag the command does not have.
public struct ProbeArguments: Sendable {
    private let integers: [String: Int]
    private let counts: [String: PositiveCount]
    private let texts: [String: String]
    private let toggles: Set<String>

    init(
        integers: [String: Int],
        counts: [String: PositiveCount],
        texts: [String: String],
        toggles: Set<String>
    ) {
        self.integers = integers
        self.counts = counts
        self.texts = texts
        self.toggles = toggles
    }

    public subscript(flag: IntegerFlag) -> Int {
        integers[flag.name] ?? flag.defaultValue
    }

    public subscript(flag: CountFlag) -> PositiveCount {
        counts[flag.name] ?? flag.defaultValue
    }

    public subscript(flag: TextFlag) -> String? {
        texts[flag.name] ?? flag.defaultValue
    }

    public subscript(flag: SwitchFlag) -> Bool {
        toggles.contains(flag.name)
    }

    /// The value only if the command line carried it, with no fallback to the declared default.
    ///
    /// For a flag whose real default comes from somewhere the parse cannot see -- the resize
    /// probe's `--samples`, which each recipe sets for itself -- so that an unwritten flag does
    /// not overwrite the recipe with the declared placeholder.
    public func provided(_ flag: IntegerFlag) -> Int? {
        integers[flag.name]
    }

    public func provided(_ flag: CountFlag) -> PositiveCount? {
        counts[flag.name]
    }
}

/// Why a parse refused, with the flag that caused it and the usage line to print after it.
public struct ProbeArgumentError: Error, Sendable {
    public enum Reason: Sendable, Equatable {
        case unknownFlag
        case repeatedFlag
        case missingValue
        case notAWholeNumber(String)
        case belowMinimum(value: Int, minimum: Int)
        case aboveMaximum(value: Int, maximum: Int)
        case notAllowed(value: String, allowed: [String])
        /// A refusal only the probe can make: a value this file accepts as well-formed but the
        /// measurement cannot use. Carries the whole sentence, since the reason is the probe's.
        case rejected(String)
    }

    public let flag: String
    public let reason: Reason
    public let usage: String

    public init(flag: String, reason: Reason, usage: String) {
        self.flag = flag
        self.reason = reason
        self.usage = usage
    }

    /// One line naming what was wrong, without the usage block.
    public var message: String {
        switch reason {
        case .unknownFlag:
            "unknown flag '\(flag)'"
        case .repeatedFlag:
            "flag '\(flag)' was given more than once; one of them would be ignored"
        case .missingValue:
            "flag '\(flag)' needs a value"
        case .notAWholeNumber(let raw):
            "flag '\(flag)' needs a whole number, not '\(raw)'"
        case .belowMinimum(let value, let minimum):
            "flag '\(flag)' must be at least \(minimum); \(value) would measure nothing"
        case .aboveMaximum(let value, let maximum):
            "flag '\(flag)' must be at most \(maximum); \(value) is out of range"
        case .notAllowed(let value, let allowed):
            "flag '\(flag)' does not accept '\(value)'; known: \(allowed.joined(separator: ", "))"
        case .rejected(let explanation):
            explanation
        }
    }

    /// What `main.swift` writes to standard error before `exit(2)`.
    public var report: String {
        message + "\n\n" + usage
    }
}
