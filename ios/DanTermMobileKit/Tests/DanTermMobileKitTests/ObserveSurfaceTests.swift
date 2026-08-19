// Behavioral tests for the pixels the phone draws a pane's grid into.
import CoreGraphics
import DanTermMobileKit
import Testing

@Test("A grid larger than the phone's view is drawn into the view's own pixels")
func observeSurfaceStaysInsideTheView() throws {
    // Intent: rendering a grid the phone cannot show at native cell metrics allocates
    // no more pixels than the view showing it has.
    // Why it exists: the phone renders whatever grid the Mac runs, so one remote
    // resize would otherwise decide how much memory this app allocates.
    // Scenario: a Mac-sized 179x50 grid arriving at a 1170x1600 pixel phone view.
    let surface = try #require(MobileObserveSurface(
        columns: 179,
        rows: 50,
        cellMetrics: try cellMetrics(widthPixels: 1170, heightPixels: 1600, displayScale: 3)
    ))
    #expect(surface.pixelWidth <= 1170)
    #expect(surface.pixelHeight <= 1600)
    #expect(surface.metrics.displayScale < 3)
}

@Test("A grid the view contains is drawn at the view's own scale")
func observeSurfaceKeepsNativeScaleWhenItFits() throws {
    let surface = try #require(MobileObserveSurface(
        columns: 20,
        rows: 10,
        cellMetrics: try cellMetrics(widthPixels: 1170, heightPixels: 1600, displayScale: 3)
    ))
    #expect(surface.metrics.displayScale == 3)
    #expect(surface.pixelWidth == surface.metrics.cellWidthPixels * 20)
    #expect(surface.pixelHeight == surface.metrics.cellHeightPixels * 10)
}

@Test("A grid with no room for a whole pixel per cell has no surface")
func observeSurfaceRefusesUndrawableGrids() throws {
    #expect(MobileObserveSurface(
        columns: 1024,
        rows: 1024,
        cellMetrics: try cellMetrics(widthPixels: 400, heightPixels: 400, displayScale: 3)
    ) == nil)
}

/// Pairs a content box with the exact pixel extent a case names, so these tests stay
/// about the fit rather than about how points and insets become pixels.
private func cellMetrics(
    widthPixels: Int,
    heightPixels: Int,
    displayScale: CGFloat
) throws -> MobileCellMetrics {
    let box = try #require(MobileContentBox(
        width: CGFloat(widthPixels) / displayScale,
        height: CGFloat(heightPixels) / displayScale,
        insetTop: 0,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 0,
        displayScale: displayScale
    ))
    return try #require(MobileCellMetrics(contentBox: box, fontSize: 11))
}
