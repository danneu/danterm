// Behavioral tests for the pairing of a content box with the metrics it resolves.
import CoreGraphics
import DanTermMobileKit
import Testing

@Test("The same extent at a different display scale resolves different cell pixels")
func cellMetricsFollowTheDisplayScale() throws {
    // Intent: the resolved cell dimensions are a function of the display scale, so the
    // same point extent read at scale 3 and at scale 2 does not resolve the same cells.
    // Why it exists: the view holds one resolved pairing across many applied records
    // instead of rebuilding it per record. That is only safe because a scale change is
    // observable here -- if it were not, held metrics could go stale with no symptom.
    // Scenario: the two display scales a handset reports, over one 393x852 point extent.
    let atThree = try cellMetrics(displayScale: 3)
    let atTwo = try cellMetrics(displayScale: 2)
    #expect(atThree.metrics.displayScale == 3)
    #expect(atTwo.metrics.displayScale == 2)
    #expect(atThree.metrics.cellWidthPixels != atTwo.metrics.cellWidthPixels)
    #expect(atThree.metrics.cellHeightPixels != atTwo.metrics.cellHeightPixels)
}

/// Pairs a phone-shaped point extent at the named scale, so a case can vary only scale.
private func cellMetrics(displayScale: CGFloat) throws -> MobileCellMetrics {
    let box = try #require(MobileContentBox(
        width: 393,
        height: 852,
        insetTop: 0,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 0,
        displayScale: displayScale
    ))
    return try #require(MobileCellMetrics(contentBox: box, fontSize: 11))
}
