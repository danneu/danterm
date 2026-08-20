// Classifies one pending PTY input segment using the tty's canonical input rules.

import Darwin

/// Prevents DanTerm from offering xnu a line that its canonical input queue cannot hold.
enum CanonicalInputDeliveryGate {
    /// xnu defines `TTYHOG` as 1024 bytes and discards input once that queue is full.
    /// See `references/xnu/bsd/sys/tty.h#TTYHOG`.
    static let capacity = 1024

    /// Returns whether input translation leaves a run that reaches the canonical capacity.
    static func isOversized(_ bytes: some Collection<UInt8>, inputFlags: tcflag_t) -> Bool {
        var runLength = 0
        for byte in bytes {
            if isDelimiter(byte, inputFlags: inputFlags) {
                runLength = 0
            } else {
                runLength += 1
                if runLength >= capacity { return true }
            }
        }
        return false
    }

    private static func isDelimiter(_ byte: UInt8, inputFlags: tcflag_t) -> Bool {
        switch byte {
        case 0x0A:
            return inputFlags & tcflag_t(INLCR) == 0
        case 0x0D:
            guard inputFlags & tcflag_t(IGNCR) == 0 else { return false }
            return inputFlags & tcflag_t(ICRNL) != 0
        default:
            return false
        }
    }
}
