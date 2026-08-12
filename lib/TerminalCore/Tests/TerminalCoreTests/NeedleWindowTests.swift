// Direct behavioral proofs for the shared streaming search matcher.
import Testing

@testable import TerminalCore

/// Pins the one matcher contract used by record and projected search scans.
struct NeedleWindowTests {
    @Test("the ring window wraps without changing match order")
    func windowWrap() {
        var matcher = NeedleWindow<Int>(needleKeys: [.scalar(0x61), .scalar(0x62)])

        #expect(matcher.record(unit(.scalar(0x78), at: 0)) == nil)
        #expect(matcher.record(unit(.scalar(0x61), at: 1)) == nil)
        #expect(matcher.record(unit(.scalar(0x62), at: 2)) == .init(start: 1, end: 3))
    }

    @Test("trailing units stay ordered after the ring wraps")
    func trailingUnits() {
        var matcher = NeedleWindow<Int>(
            needleKeys: [.scalar(0x61), .scalar(0x62), .scalar(0x63)]
        )

        for (index, key) in [0x77, 0x78, 0x79, 0x7A].enumerated() {
            _ = matcher.record(unit(.scalar(UInt32(key)), at: index))
        }

        #expect(matcher.trailingUnits == [
            unit(.scalar(0x79), at: 2),
            unit(.scalar(0x7A), at: 3),
        ])
    }

    @Test("a single-unit needle matches without retaining context")
    func singleUnitNeedle() {
        var matcher = NeedleWindow<Int>(needleKeys: [.scalar(0x61)])

        #expect(matcher.record(unit(.scalar(0x61), at: 4)) == .init(start: 4, end: 5))
        #expect(matcher.trailingUnits.isEmpty)
    }

    @Test("recording feeds report overlapping matches")
    func overlappingMatches() {
        var matcher = NeedleWindow<Int>(needleKeys: [.scalar(0x61), .scalar(0x61)])
        var matches: [NeedleWindow<Int>.Match] = []

        for index in 0..<3 {
            if let match = matcher.record(unit(.scalar(0x61), at: index)) {
                matches.append(match)
            }
        }

        #expect(matches == [
            .init(start: 0, end: 2),
            .init(start: 1, end: 3),
        ])
    }

    @Test("join context advances the same window without recording its own match")
    func mixedJoinContextAndRecordingFeeds() {
        let needle: [SearchGraphemeKey] = [.scalar(0x61), .scalar(0x62), .scalar(0x63)]
        var joined = NeedleWindow<Int>(needleKeys: needle)
        var recorded = NeedleWindow<Int>(needleKeys: needle)

        joined.join(unit(.scalar(0x61), at: 0))
        joined.join(unit(.scalar(0x62), at: 1))
        recorded.join(unit(.scalar(0x61), at: 0))
        recorded.join(unit(.scalar(0x62), at: 1))

        joined.join(unit(.scalar(0x63), at: 2))
        let match = recorded.record(unit(.scalar(0x63), at: 2))

        #expect(match == .init(start: 0, end: 3))
        #expect(joined.trailingUnits == recorded.trailingUnits)
    }

    private func unit(
        _ key: SearchGraphemeKey,
        at position: Int
    ) -> NeedleWindow<Int>.Unit {
        NeedleWindow.Unit(key: key, start: position, end: position + 1)
    }
}
