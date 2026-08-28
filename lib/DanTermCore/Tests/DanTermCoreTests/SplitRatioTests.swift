// Admission tests for the bounded split ratio model value.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct SplitRatioTests {
    @Test("only finite ratios from zero through one admit")
    func onlyFiniteBoundedRatiosAdmit() {
        #expect(SplitRatio(CGFloat(0))?.value == 0)
        #expect(SplitRatio(CGFloat(0.3))?.value == 0.3)
        #expect(SplitRatio(CGFloat(1))?.value == 1)
        #expect(SplitRatio(CGFloat(-0.1)) == nil)
        #expect(SplitRatio(CGFloat(1.1)) == nil)
        #expect(SplitRatio(CGFloat.infinity) == nil)
        #expect(SplitRatio(-CGFloat.infinity) == nil)
        #expect(SplitRatio(CGFloat.nan) == nil)
    }
}
