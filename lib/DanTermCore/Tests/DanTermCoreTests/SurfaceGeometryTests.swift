// Swift Testing migration of the legacy `tests/SurfaceGeometryTests.swift`
// harness suite. Pins pure `surfaceGeometry(logicalSize:backingSize:)` against
// the Retina / non-Retina / fractional / zero-size matrix the legacy suite
// asserted, with Intent / Why / Scenario preambles per AGENTS.md.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct SurfaceGeometryTests {
    @Test("surfaceGeometry: Retina 2x derives scale and backing pixels")
    func retina2xDerivesScaleAndBackingPixels() {
        // Intent: a 2x Retina logical/backing pair derives xScale=yScale=2 and
        //   the integer backing pixel dimensions verbatim.
        // Why it exists: pins the standard Retina path so a refactor that
        //   re-orders the scale + pixel derivation cannot drop a dimension.
        // Scenario: spec-first happy path -- a Retina pane reports 800x600
        //   logical / 1600x1200 backing and the Ghostty surface must scale 2x.
        #expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 1600, height: 1200)
        ) == SurfaceGeometry(xScale: 2, yScale: 2, pixelWidth: 1600, pixelHeight: 1200))
    }

    @Test("surfaceGeometry: non-Retina 1x derives scale 1")
    func nonRetina1xDerivesScale1() {
        // Intent: a 1:1 logical/backing pair derives xScale=yScale=1 (and
        //   pixel dims equal the integer logical dims).
        // Why it exists: pins the non-Retina path so the Retina-aware scale
        //   derivation does not produce a fractional scale on plain displays.
        // Scenario: spec-first non-Retina check -- a 1x display reports
        //   identical logical and backing 800x600 and the surface scales 1:1.
        #expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 800, height: 600)
        ) == SurfaceGeometry(xScale: 1, yScale: 1, pixelWidth: 800, pixelHeight: 600))
    }

    @Test("surfaceGeometry: derives x and y scale independently")
    func derivesXAndYScaleIndependently() {
        // Intent: x and y backing factors are computed independently, so a
        //   100x100 logical with 200x150 backing yields xScale=2 and yScale=1.5.
        // Why it exists: pins the per-axis derivation so a refactor that
        //   shares a single scale factor cannot silently squash one dimension.
        // Scenario: spec-first asymmetric check -- a display configuration
        //   where the horizontal and vertical backing-to-logical ratios differ.
        #expect(surfaceGeometry(
            logicalSize: CGSize(width: 100, height: 100),
            backingSize: CGSize(width: 200, height: 150)
        ) == SurfaceGeometry(xScale: 2, yScale: 1.5, pixelWidth: 200, pixelHeight: 150))
    }

    @Test("surfaceGeometry: fractional backing pixels truncate")
    func fractionalBackingPixelsTruncate() {
        // Intent: fractional backing dimensions truncate (floor) into the
        //   integer pixelWidth / pixelHeight outputs.
        // Why it exists: pins the truncation convention so a "round" or "ceil"
        //   regression cannot ship a one-pixel oversize surface that would
        //   blur sub-pixel content.
        // Scenario: spec-first truncation check -- a backing of 1601.9 x
        //   1200.4 must surface 1601 x 1200 integer pixels.
        let geo = surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 1601.9, height: 1200.4)
        )
        #expect(geo?.pixelWidth == 1601)
        #expect(geo?.pixelHeight == 1200)
    }

    @Test("surfaceGeometry: zero logical size returns nil")
    func zeroLogicalSizeReturnsNil() {
        // Intent: a zero logical size returns nil (no valid geometry).
        // Why it exists: pins the divide-by-zero guard against a refactor
        //   that produces NaN/Inf scales for an unsized view.
        // Scenario: spec-first guard check -- a hidden / zero-sized pane must
        //   not derive a surface geometry; the caller skips Ghostty resize.
        #expect(surfaceGeometry(
            logicalSize: CGSize(width: 0, height: 0),
            backingSize: CGSize(width: 1600, height: 1200)
        ) == nil)
    }

    @Test("surfaceGeometry: zero backing size returns nil")
    func zeroBackingSizeReturnsNil() {
        // Intent: a zero backing size returns nil (no valid pixel grid).
        // Why it exists: pins the inverse zero-side guard so a backing-store
        //   that has not yet materialized does not produce a zero-pixel surface.
        // Scenario: spec-first guard check -- a pane attached to a window that
        //   has not laid out yet must produce nil rather than a 0x0 surface.
        #expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 0, height: 0)
        ) == nil)
    }

    @Test("surfaceGeometry: single zero dimension returns nil")
    func singleZeroDimensionReturnsNil() {
        // Intent: a partially-zero logical or backing size (one axis zero)
        //   also returns nil.
        // Why it exists: pins the per-axis guard so a refactor that only
        //   checks the area (width * height) cannot let through a degenerate
        //   stripe geometry.
        // Scenario: spec-first guard check -- a pane mid-layout with a single
        //   collapsed axis must still produce nil.
        #expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 0),
            backingSize: CGSize(width: 1600, height: 0)
        ) == nil)
    }
}
