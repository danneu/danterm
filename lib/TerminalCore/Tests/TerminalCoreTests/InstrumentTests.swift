// The nesting contract of the shared instrument tally.
//
// Every cost claim in this package is measured through one `Instrument.measure` scope, and
// several of those scopes sit inside each other -- a search test measures index maintenance
// around a body that also measures projected rows. One tally shared by every instrument makes
// that nesting a real question, where nine separate task-locals made it accidental.
//
// What belongs here: what a measurement reports when another measurement runs inside it. What
// does not: what any particular instrument counts, which is the concern of the test that asserts
// on that instrument.
import Testing

@testable import TerminalCore

@Suite("Instrument tally")
struct InstrumentTests {
    @Test("An inner measurement of another instrument leaves the outer result intact")
    func nestedOtherInstrumentDoesNotDisturbTheOuterCount() {
        var inner = 0
        let outer = Instrument.displayRowLocate.measure {
            Instrument.displayRowLocate.record()
            inner = Instrument.projectionRow.measure {
                Instrument.displayRowLocate.record()
                Instrument.projectionRow.record(count: 7)
            }
            Instrument.displayRowLocate.record()
        }

        #expect(inner == 7)
        // The three locates include the one spent inside the inner scope: an enclosing
        // measurement observes its own body in full, and a nested scope of a different
        // instrument is not a hole in it.
        #expect(outer == 3)
    }

    @Test("An inner measurement of the same instrument neither zeroes nor doubles the outer")
    func nestedSameInstrumentCountsOncePerScope() {
        var inner = 0
        let outer = Instrument.projectionRow.measure {
            Instrument.projectionRow.record(count: 2)
            inner = Instrument.projectionRow.measure {
                Instrument.projectionRow.record(count: 3)
            }
            Instrument.projectionRow.record(count: 5)
        }

        #expect(inner == 3)
        #expect(outer == 10)
    }

    @Test("Recording with no measurement in scope is a no-op")
    func recordingOutsideAnyMeasurementDoesNothing() {
        Instrument.displayRowLocate.record()

        let measured = Instrument.displayRowLocate.measure {
            Instrument.displayRowLocate.record()
        }
        #expect(measured == 1)
    }
}
