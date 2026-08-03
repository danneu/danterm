// The one native piece of the live btop stimulus: it posts real arrow-key
// CGEvents at one owned process, and decides nothing.
//
// Everything about *when* a key goes down, repeats, or comes up is timing logic
// and lives in `terminal_btop_stimulus.py`, where it is proved against an
// injected clock. This arm exists only because posting an event the AppKit
// responder chain will accept, and asking whether this process is even allowed
// to, both require macOS APIs that no hermetic test can stand in for. It stays
// deliberately dumb: read a verb, post an event, and never infer a second one.
//
// Protocol: one command per stdin line -- `press <down|up>`, `repeat <down|up>`,
// `release <down|up>` -- plus a `preflight` argv mode that reports permission as
// JSON and exits. Closing stdin or signalling the process releases whatever key
// is held, so no exit path can leave an arrow stuck down (I5).
import CoreGraphics
import Dispatch
import Foundation

/// The two arrow keys this workload holds, named so the driver never sends raw key codes.
enum ArrowDirection: String {
    case down
    case up

    /// `kVK_DownArrow` / `kVK_UpArrow`, which live in Carbon's HIToolbox and are
    /// restated here rather than importing Carbon for two integers.
    var keyCode: CGKeyCode {
        switch self {
        case .down: 125
        case .up: 126
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("terminal-btop-stimulus-arm: \(message)\n".utf8))
    exit(2)
}

/// Posts arrow key events to one pid and remembers which key it left down.
///
/// The held-key bookkeeping is the point: it is what lets stdin closing, a
/// signal, or a driver crash still produce the matching key-up. Serialized on
/// its own queue because the signal sources below release from a different
/// thread than the stdin loop presses on.
final class ArrowPoster {
    private let pid: pid_t
    private let source: CGEventSource?
    private let queue = DispatchQueue(label: "danterm.btop-stimulus-arm")
    private var held: ArrowDirection?

    init(pid: pid_t) {
        self.pid = pid
        // `.hidSystemState` so the synthesized events carry the same modifier
        // state a real keypress would; a private source reports no modifiers and
        // would make a held Shift silently vanish from the stimulus.
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    func press(_ direction: ArrowDirection) {
        queue.sync {
            post(direction, keyDown: true, autorepeat: false)
            held = direction
        }
    }

    func repeatKey(_ direction: ArrowDirection) {
        queue.sync { post(direction, keyDown: true, autorepeat: true) }
    }

    func release(_ direction: ArrowDirection) {
        queue.sync {
            post(direction, keyDown: false, autorepeat: false)
            if held == direction { held = nil }
        }
    }

    /// Releases whatever is still down. Every exit path calls this.
    func releaseHeldKey() {
        queue.sync {
            guard let direction = held else { return }
            post(direction, keyDown: false, autorepeat: false)
            held = nil
        }
    }

    private func post(_ direction: ArrowDirection, keyDown: Bool, autorepeat: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: direction.keyCode,
            keyDown: keyDown
        ) else {
            fail("could not create a keyboard event for \(direction.rawValue)")
        }
        // A synthesized key-down does not auto-repeat the way real HID input
        // does, so the driver emits the repeat train itself; this field is what
        // makes the app see those events as a held key rather than as N distinct
        // presses.
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        // Targeted at one pid, never posted to the session tap: the run owns
        // exactly one app (I3), and a session-wide post would reach whatever the
        // operator happens to have in front.
        event.postToPid(pid)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: terminal-btop-stimulus-arm preflight | terminal-btop-stimulus-arm post <pid>")
}

if arguments[1] == "preflight" {
    // Preflight, never request: requesting would raise a system prompt in the
    // middle of an automated run and block it until someone clicked.
    let granted = CGPreflightPostEventAccess()
    let permission: [String: Any] = [
        "granted": granted,
        "mechanism": "CGEventPostToPid",
    ]
    let data = try JSONSerialization.data(withJSONObject: permission, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    exit(0)
}

guard arguments[1] == "post", arguments.count == 3, let pid = pid_t(arguments[2]) else {
    fail("usage: terminal-btop-stimulus-arm post <pid>")
}

let poster = ArrowPoster(pid: pid)
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    // Ignore the default disposition first: the dispatch source only observes,
    // it does not suppress the kernel's default terminate.
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        poster.releaseHeldKey()
        exit(128 + number)
    }
    source.resume()
    signalSources.append(source)
}

while let line = readLine(strippingNewline: true) {
    let fields = line.split(separator: " ")
    guard fields.count == 2, let direction = ArrowDirection(rawValue: String(fields[1])) else {
        poster.releaseHeldKey()
        fail("unrecognized command: \(line)")
    }
    switch fields[0] {
    case "press": poster.press(direction)
    case "repeat": poster.repeatKey(direction)
    case "release": poster.release(direction)
    default:
        poster.releaseHeldKey()
        fail("unrecognized command: \(line)")
    }
}
// stdin closed -- the driver is gone, so nothing else will ever send the key-up.
poster.releaseHeldKey()
