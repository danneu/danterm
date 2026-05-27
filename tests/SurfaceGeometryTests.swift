// Unit tests for pure Ghostty surface geometry derivation.

import Foundation

func surfaceGeometryTests() {
    test("surfaceGeometry: Retina 2x derives scale and backing pixels") {
        try expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 1600, height: 1200)
        ) == SurfaceGeometry(xScale: 2, yScale: 2, pixelWidth: 1600, pixelHeight: 1200))
    }

    test("surfaceGeometry: non-Retina 1x derives scale 1") {
        try expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 800, height: 600)
        ) == SurfaceGeometry(xScale: 1, yScale: 1, pixelWidth: 800, pixelHeight: 600))
    }

    test("surfaceGeometry: derives x and y scale independently") {
        try expect(surfaceGeometry(
            logicalSize: CGSize(width: 100, height: 100),
            backingSize: CGSize(width: 200, height: 150)
        ) == SurfaceGeometry(xScale: 2, yScale: 1.5, pixelWidth: 200, pixelHeight: 150))
    }

    test("surfaceGeometry: fractional backing pixels truncate") {
        let geo = surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 1601.9, height: 1200.4)
        )
        try expectEqual(geo?.pixelWidth, 1601)
        try expectEqual(geo?.pixelHeight, 1200)
    }

    test("surfaceGeometry: zero logical size returns nil") {
        try expect(surfaceGeometry(
            logicalSize: CGSize(width: 0, height: 0),
            backingSize: CGSize(width: 1600, height: 1200)
        ) == nil)
    }

    test("surfaceGeometry: zero backing size returns nil") {
        try expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 600),
            backingSize: CGSize(width: 0, height: 0)
        ) == nil)
    }

    test("surfaceGeometry: single zero dimension returns nil") {
        try expect(surfaceGeometry(
            logicalSize: CGSize(width: 800, height: 0),
            backingSize: CGSize(width: 1600, height: 0)
        ) == nil)
    }
}
