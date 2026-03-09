import Foundation

func dropZoneTests() {
    print("DropZone Tests...")

    let size = DropZoneSize(width: 400, height: 300)

    // MARK: - Edge bands

    test("testDropZoneLeft") {
        // x=50 is 12.5% from left → left band
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 50, y: 150), paneSize: size)
        try expectEqual(result, .splitLeft)
    }

    test("testDropZoneRight") {
        // x=350 is 87.5% → right band
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 350, y: 150), paneSize: size)
        try expectEqual(result, .splitRight)
    }

    test("testDropZoneBottom") {
        // y=37 is 12.3% from bottom → bottom band (macOS Y=0 at bottom)
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 37), paneSize: size)
        try expectEqual(result, .splitBottom)
    }

    test("testDropZoneTop") {
        // y=263 is 87.7% → top band
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 263), paneSize: size)
        try expectEqual(result, .splitTop)
    }

    // MARK: - Center

    test("testDropZoneCenter") {
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 150), paneSize: size)
        try expectEqual(result, .swap)
    }

    test("testDropZoneExactCenter") {
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 150), paneSize: size)
        try expectEqual(result, .swap)
    }

    // MARK: - Corners

    test("testDropZoneCornerCloserToTop") {
        // Top-left corner, closer to top edge than left edge
        // x=80 → fx=0.2 (in left band), y=285 → fy=0.95 (in top band)
        // hDist = min(0.2, 0.8) = 0.2, vDist = min(0.95, 0.05) = 0.05
        // vDist < hDist → top wins
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 80, y: 285), paneSize: size)
        try expectEqual(result, .splitTop)
    }

    test("testDropZoneCornerCloserToLeft") {
        // Top-left corner, closer to left edge than top edge
        // x=20 → fx=0.05 (in left band), y=240 → fy=0.8 (in top band)
        // hDist = min(0.05, 0.95) = 0.05, vDist = min(0.8, 0.2) = 0.2
        // hDist < vDist → left wins
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 20, y: 240), paneSize: size)
        try expectEqual(result, .splitLeft)
    }

    test("testDropZoneCornerEquidistantHorizontalWins") {
        // Exact corner where distances are equal
        // x=100 → fx=0.25 (boundary), y=75 → fy=0.25 (boundary)
        // hDist = min(0.25, 0.75) = 0.25, vDist = min(0.25, 0.75) = 0.25
        // Equal → horizontal wins (left)
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 100, y: 75), paneSize: size)
        try expectEqual(result, .splitLeft)
    }

    // MARK: - Boundary (edge band boundary)

    test("testDropZoneBoundaryIsEdge") {
        // Exactly at 25% threshold → still in edge band (<=)
        // x=100 → fx=0.25, y=150 → fy=0.5 (center)
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 100, y: 150), paneSize: size)
        try expectEqual(result, .splitLeft)
    }

    // MARK: - Invalid inputs

    test("testDropZoneZeroWidth") {
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 0, y: 0), paneSize: DropZoneSize(width: 0, height: 100))
        try expect(result == nil, "zero width returns nil")
    }

    test("testDropZoneZeroHeight") {
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 0, y: 0), paneSize: DropZoneSize(width: 100, height: 0))
        try expect(result == nil, "zero height returns nil")
    }

    test("testDropZoneCursorOutside") {
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: -10, y: 150), paneSize: size)
        try expect(result == nil, "cursor outside returns nil")
    }

    test("testDropZoneCursorOutsideRight") {
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 500, y: 150), paneSize: size)
        try expect(result == nil, "cursor past right edge returns nil")
    }
}
