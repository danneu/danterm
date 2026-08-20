// Deterministic tests for the canonical-mode PTY input scanner.

import Darwin
import Testing
@testable import TerminalPTYHost

struct CanonicalInputDeliveryGateTests {
    @Test("canonical capacity is counted between translated delimiters")
    func capacityIsCountedBetweenTranslatedDelimiters() {
        let fullRun = [UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity)
        let splitRuns = [UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity - 1)
            + [0x0A]
            + [UInt8](repeating: 0x62, count: CanonicalInputDeliveryGate.capacity - 1)

        #expect(CanonicalInputDeliveryGate.isOversized(fullRun, inputFlags: 0))
        #expect(CanonicalInputDeliveryGate.isOversized(splitRuns, inputFlags: 0) == false)
    }

    @Test("input translation decides whether CR and LF delimit canonical input")
    func inputTranslationDecidesDelimiters() {
        let prefix = [UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity - 1)
        let suffix: [UInt8] = [0x62]

        #expect(CanonicalInputDeliveryGate.isOversized(
            prefix + [UInt8(0x0D)] + suffix,
            inputFlags: tcflag_t(IGNCR | ICRNL)
        ))
        #expect(CanonicalInputDeliveryGate.isOversized(
            prefix + [UInt8(0x0D)] + suffix,
            inputFlags: tcflag_t(ICRNL)
        ) == false)
        #expect(CanonicalInputDeliveryGate.isOversized(
            prefix + [UInt8(0x0A)] + suffix,
            inputFlags: tcflag_t(INLCR)
        ))
    }
}
