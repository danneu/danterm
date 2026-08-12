// Pure OSC payload decoding and normalization with no screen state. TerminalCore is
// Foundation-free, so the namespace keeps its small byte codecs in the standard library.

/// Groups the pure decoding decisions used by `Terminal`'s stateful OSC dispatch.
enum OSCPayload {
    static func decodeBase64(
        _ encoded: ArraySlice<UInt8>,
        maximumByteCount: Int
    ) -> [UInt8]? {
        guard encoded.count.isMultiple(of: 4) else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(min(maximumByteCount, encoded.count / 4 * 3))
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let aIndex = index
            let bIndex = encoded.index(after: aIndex)
            let cIndex = encoded.index(after: bIndex)
            let dIndex = encoded.index(after: cIndex)
            let next = encoded.index(after: dIndex)
            guard let a = base64Value(encoded[aIndex]), let b = base64Value(encoded[bIndex]) else {
                return nil
            }
            let cByte = encoded[cIndex]
            let dByte = encoded[dIndex]
            guard appendDecodedBase64Quartet(
                a: a,
                b: b,
                cByte: cByte,
                dByte: dByte,
                isFinal: next == encoded.endIndex,
                maximumByteCount: maximumByteCount,
                to: &decoded
            ) else { return nil }
            index = next
        }
        return decoded
    }

    static func decodedCanonicalBase64(
        _ bytes: ArraySlice<UInt8>,
        maximumByteCount: Int
    ) -> String? {
        guard bytes.isEmpty == false,
              let decoded = decodeBase64(bytes, maximumByteCount: maximumByteCount),
              let value = String(validating: decoded, as: UTF8.self),
              value.isEmpty == false
        else { return nil }
        return value
    }

    static func percentDecoded(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        var result: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] != 0x25 {
                result.append(bytes[index])
                index += 1
                continue
            }
            guard index + 2 < bytes.endIndex,
                  let high = hexadecimalValue(bytes[index + 1]),
                  let low = hexadecimalValue(bytes[index + 2])
            else { return nil }
            result.append(high * 16 + low)
            index += 3
        }
        return result
    }

    static func parseOSCSelector(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in bytes {
            guard (0x30...0x39).contains(byte) else { return nil }
            let multiplied = value.multipliedReportingOverflow(by: 10)
            guard multiplied.overflow == false else { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(Int(byte - 0x30))
            guard added.overflow == false else { return nil }
            value = added.partialValue
        }
        return value
    }

    static func canonicalConEmuSelector(_ bytes: ArraySlice<UInt8>) -> Int? {
        for value in 1...12 where bytes.elementsEqual(String(value).utf8) {
            return value
        }
        return nil
    }

    static func progressPercent(_ bytes: ArraySlice<UInt8>) -> UInt8? {
        guard bytes.isEmpty == false, bytes.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int(String(decoding: bytes, as: UTF8.self)), value <= 100
        else { return nil }
        return UInt8(value)
    }

    static func canonicalExitStatus(_ bytes: ArraySlice<UInt8>) -> UInt8? {
        guard bytes.isEmpty == false,
              bytes.allSatisfy({ (0x30...0x39).contains($0) }),
              bytes.first != 0x30 || bytes.count == 1,
              let value = UInt8(String(decoding: bytes, as: UTF8.self))
        else { return nil }
        return value
    }

    static func oscColorComponent(_ component: UInt8) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let high = digits[Int(component >> 4)]
        let low = digits[Int(component & 0x0F)]
        return String(decoding: [high, low, high, low], as: UTF8.self)
    }

    static func osc8ExplicitId(in params: String) -> String? {
        for field in params.split(separator: ":", omittingEmptySubsequences: false) {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2, pieces[0] == "id" {
                return String(pieces[1])
            }
        }
        return nil
    }

    static func localFilePath(
        from bytes: ArraySlice<UInt8>,
        machineHostname: String?
    ) -> String? {
        let hostStart = bytes.index(bytes.startIndex, offsetBy: 7, limitedBy: bytes.endIndex)
        guard bytes.starts(with: "file://".utf8), let hostStart,
              let slash = bytes[hostStart...].firstIndex(of: 0x2F)
        else { return nil }
        guard let host = String(validating: bytes[hostStart..<slash], as: UTF8.self),
              namesThisMachine(host, machineHostname: machineHostname)
        else { return nil }
        guard let decodedPathBytes = percentDecoded(bytes[slash...]),
              let path = String(validating: decodedPathBytes, as: UTF8.self)
        else { return nil }
        return path
    }

    private static func appendDecodedBase64Quartet(
        a: UInt8,
        b: UInt8,
        cByte: UInt8,
        dByte: UInt8,
        isFinal: Bool,
        maximumByteCount: Int,
        to decoded: inout [UInt8]
    ) -> Bool {
        decoded.append((a << 2) | (b >> 4))
        if cByte == 0x3D {
            guard isFinal, dByte == 0x3D, b & 0x0F == 0 else { return false }
        } else {
            guard let c = base64Value(cByte) else { return false }
            decoded.append((b << 4) | (c >> 2))
            if dByte == 0x3D {
                guard isFinal, c & 0x03 == 0 else { return false }
            } else {
                guard let d = base64Value(dByte) else { return false }
                decoded.append((c << 6) | d)
            }
        }
        return decoded.count <= maximumByteCount
    }

    private static func base64Value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x41...0x5A: byte - 0x41
        case 0x61...0x7A: byte - 0x61 + 26
        case 0x30...0x39: byte - 0x30 + 52
        case 0x2B: 62
        case 0x2F: 63
        default: nil
        }
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    // Accept only the spellings macOS manufactures for this host: ASCII case, one trailing
    // dot, and a trailing `.local` label. A first-label match would let `mac.evil.com` from
    // an ssh session set the pane's working directory.
    private static func namesThisMachine(_ host: String, machineHostname: String?) -> Bool {
        if host == "localhost" { return true }
        guard let machineHostname else { return false }
        let normalized = normalizedHost(host)
        return !normalized.isEmpty && normalized == normalizedHost(machineHostname)
    }

    private static func normalizedHost(_ host: String) -> [UInt8] {
        var bytes = Array(host.utf8)
        for index in bytes.indices where (0x41...0x5A).contains(bytes[index]) {
            bytes[index] += 0x20
        }
        if bytes.last == 0x2E { bytes.removeLast() }
        let localSuffix = Array(".local".utf8)
        if bytes.count > localSuffix.count, bytes.suffix(localSuffix.count).elementsEqual(localSuffix) {
            bytes.removeLast(localSuffix.count)
        }
        return bytes
    }
}
