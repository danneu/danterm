// The fixture plumbing every real-PTY suite needs before it can launch anything: where the
// built helper binaries live in `.build`, how to quote a path into a `/bin/sh -c` line, and
// how to build a marker the launch command does not spell itself.
//
// It lives here rather than in one of the test targets because all of them need it and each
// had grown its own byte-identical copy; the marker helper in particular carries an argument
// about what a `waitForOutput` actually proves, and that argument has to have one home.
// Fixture *commands* only -- anything that awaits, fences, or drives a host belongs next to
// the async adapters in TerminalPTYHostAsyncSupport.swift.
import Foundation
import Testing

/// Locates a SwiftPM-built helper executable by name, searching the package's `.build`
/// directory so tests do not depend on which toolchain/triple subdirectory produced it.
public func builtExecutable(named name: String) throws -> String {
    let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = packageDirectory.appending(path: ".build", directoryHint: .isDirectory)
    let candidates = try FileManager.default.subpathsOfDirectory(atPath: buildDirectory.path)
        .filter { $0.hasSuffix("/debug/\(name)") }
        .map { buildDirectory.appending(path: $0).path }
        .filter(FileManager.default.isExecutableFile(atPath:))
        .sorted()
    return try #require(candidates.first)
}

/// The PTY session bootstrap every host under test spawns through.
public func bootstrapExecutable() throws -> String {
    try builtExecutable(named: "PTYSessionBootstrap")
}

/// The controllable child (`hold`, `sync`, `resize`, ...) most PTY fixtures launch.
public func probeExecutable() throws -> String {
    try builtExecutable(named: "PTYProbe")
}

/// Quotes a value for interpolation into a `sh -c` command line.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Shell that prints a `__MARKER__` the launch command itself never spells.
///
/// The command line is echoed to the tty before the child runs it, so a command
/// containing its own marker satisfies `waitForOutput(containing:)` immediately: the
/// wait then means "the shell read this line", not "the child reached this point", and
/// the test proceeds against a pane that has produced nothing. Assembling the marker at
/// runtime is what makes the wait mean what it reads as. `stty -echo` does not help --
/// the line is echoed as it is read, before any command in it runs.
public func printMarker(_ body: String, newline: Bool = true) -> String {
    "m=\(body); printf '__%s__\(newline ? "\\n" : "")' \"$m\""
}
