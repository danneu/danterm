// Direct boundary tests for the pure OSC payload decoder namespace.
import Testing
@testable import TerminalCore

@Suite("OSC payload decoders")
struct OSCPayloadTests {
    @Test("base64 decoding enforces canonical padding and the decoded byte cap")
    func base64Boundaries() {
        #expect(OSCPayload.decodeBase64(bytes("TQ=="), maximumByteCount: 1) == [0x4D])
        #expect(OSCPayload.decodeBase64(bytes("TR=="), maximumByteCount: 1) == nil)
        #expect(OSCPayload.decodeBase64(bytes("TWE="), maximumByteCount: 1) == nil)
    }

    @Test("canonical base64 produces non-empty UTF-8 within its explicit cap")
    func canonicalBase64Boundaries() {
        #expect(OSCPayload.decodedCanonicalBase64(bytes("b2s="), maximumByteCount: 2) == "ok")
        #expect(OSCPayload.decodedCanonicalBase64(bytes(""), maximumByteCount: 2) == nil)
        #expect(OSCPayload.decodedCanonicalBase64(bytes("/w=="), maximumByteCount: 1) == nil)
    }

    @Test("percent decoding accepts complete hex escapes and rejects truncation")
    func percentDecodeBoundaries() {
        #expect(OSCPayload.percentDecoded(bytes("/a%20b")) == Array("/a b".utf8))
        #expect(OSCPayload.percentDecoded(bytes("/a%2")) == nil)
    }

    @Test("OSC selector parsing rejects non-digits and integer overflow")
    func selectorBoundaries() {
        #expect(OSCPayload.parseOSCSelector(bytes("1337")) == 1_337)
        #expect(OSCPayload.parseOSCSelector(bytes("1x")) == nil)
        #expect(OSCPayload.parseOSCSelector(bytes("999999999999999999999999999999")) == nil)
    }

    @Test("ConEmu selectors accept only canonical decimal values one through twelve")
    func conEmuSelectorBoundaries() {
        #expect(OSCPayload.canonicalConEmuSelector(bytes("1")) == 1)
        #expect(OSCPayload.canonicalConEmuSelector(bytes("12")) == 12)
        #expect(OSCPayload.canonicalConEmuSelector(bytes("04")) == nil)
        #expect(OSCPayload.canonicalConEmuSelector(bytes("13")) == nil)
    }

    @Test("progress percentages stop at one hundred")
    func progressBoundaries() {
        #expect(OSCPayload.progressPercent(bytes("100")) == 100)
        #expect(OSCPayload.progressPercent(bytes("101")) == nil)
        #expect(OSCPayload.progressPercent(bytes("")) == nil)
    }

    @Test("exit statuses use canonical decimal UInt8 spelling")
    func exitStatusBoundaries() {
        #expect(OSCPayload.canonicalExitStatus(bytes("0")) == 0)
        #expect(OSCPayload.canonicalExitStatus(bytes("255")) == 255)
        #expect(OSCPayload.canonicalExitStatus(bytes("01")) == nil)
        #expect(OSCPayload.canonicalExitStatus(bytes("256")) == nil)
    }

    @Test("OSC color components repeat lowercase hexadecimal bytes")
    func colorComponent() {
        #expect(OSCPayload.oscColorComponent(0x00) == "0000")
        #expect(OSCPayload.oscColorComponent(0xAB) == "abab")
    }

    @Test("OSC 8 explicit ids use the first exact id field")
    func explicitHyperlinkId() {
        #expect(OSCPayload.osc8ExplicitId(in: "foo=x:id=chosen:id=later") == "chosen")
        #expect(OSCPayload.osc8ExplicitId(in: "identity=nope") == nil)
        // An empty value is no id, and first-wins still applies to it: a later
        // non-empty field does not rescue the empty first one.
        #expect(OSCPayload.osc8ExplicitId(in: "id=") == nil)
        #expect(OSCPayload.osc8ExplicitId(in: "id=:id=later") == nil)
    }

    @Test("OSC 7 paths require a local host and complete percent escapes")
    func localFilePathBoundaries() {
        #expect(
            OSCPayload.localFilePath(
                from: bytes("file://MAC.Local./tmp/a%20b"),
                machineHostname: "mac"
            ) == "/tmp/a b"
        )
        #expect(
            OSCPayload.localFilePath(
                from: bytes("file://mac.evil.com/tmp"),
                machineHostname: "mac"
            ) == nil
        )
        #expect(
            OSCPayload.localFilePath(
                from: bytes("file://mac/tmp/%"),
                machineHostname: "mac"
            ) == nil
        )
    }

    private func bytes(_ string: String) -> ArraySlice<UInt8> {
        Array(string.utf8)[...]
    }
}
