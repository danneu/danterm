// Unit tests for the pure scrollbar coordinate math functions.

import Foundation

func scrollbarMathTests() {
    // MARK: - documentHeight

    test("scrollbarDocumentHeight: returns contentHeight when cellHeight is zero") {
        let result = scrollbarDocumentHeight(contentHeight: 600, cellHeight: 0, total: 1000, len: 40)
        try expectEqual(result, 600)
    }

    test("scrollbarDocumentHeight: correct with scrollback") {
        // 1000 total rows * 15pt cell + padding
        // padding = 600 - (40 * 15) = 0
        let result = scrollbarDocumentHeight(contentHeight: 600, cellHeight: 15, total: 1000, len: 40)
        try expectEqual(result, 15000)
    }

    test("scrollbarDocumentHeight: includes padding when content doesn't fill grid exactly") {
        // padding = 600 - (38 * 15) = 30
        // total height = 1000 * 15 + 30 = 15030
        let result = scrollbarDocumentHeight(contentHeight: 600, cellHeight: 15, total: 1000, len: 38)
        try expectEqual(result, 15030)
    }

    // MARK: - scrollOffsetY

    test("scrollbarOffsetY: at bottom of scrollback, offsetY is 0") {
        // At bottom: offset = total - len
        let result = scrollbarOffsetY(total: 1000, offset: 960, len: 40, cellHeight: 15)
        try expectEqual(result, 0)
    }

    test("scrollbarOffsetY: at top of scrollback, offsetY is maximal") {
        // At top: offset = 0, so offsetY = (1000 - 0 - 40) * 15 = 14400
        let result = scrollbarOffsetY(total: 1000, offset: 0, len: 40, cellHeight: 15)
        try expectEqual(result, 14400)
    }

    test("scrollbarOffsetY: mid-scrollback") {
        // offset = 500, so offsetY = (1000 - 500 - 40) * 15 = 6900
        let result = scrollbarOffsetY(total: 1000, offset: 500, len: 40, cellHeight: 15)
        try expectEqual(result, 6900)
    }

    // MARK: - scrollbarRowFromPosition

    test("scrollbarRowFromPosition: returns 0 when cellHeight is zero") {
        let result = scrollbarRowFromPosition(documentHeight: 15000, visibleOriginY: 0, visibleHeight: 600, cellHeight: 0)
        try expectEqual(result, 0)
    }

    test("scrollbarRowFromPosition: at bottom of document returns row 0") {
        // visibleOriginY = docHeight - visibleHeight = 14400
        let result = scrollbarRowFromPosition(documentHeight: 15000, visibleOriginY: 14400, visibleHeight: 600, cellHeight: 15)
        try expectEqual(result, 0)
    }

    test("scrollbarRowFromPosition: at top of document returns max row") {
        // scrollOffset = 15000 - 0 - 600 = 14400, row = 14400/15 = 960
        let result = scrollbarRowFromPosition(documentHeight: 15000, visibleOriginY: 0, visibleHeight: 600, cellHeight: 15)
        try expectEqual(result, 960)
    }

    // MARK: - Round-trip

    test("scrollbar round-trip: offset -> offsetY -> row produces original offset") {
        let total: UInt64 = 1000
        let len: UInt64 = 40
        let cellHeight: CGFloat = 15
        let contentHeight: CGFloat = CGFloat(len) * cellHeight

        for offset: UInt64 in [0, 100, 500, 960] {
            let offsetY = scrollbarOffsetY(total: total, offset: offset, len: len, cellHeight: cellHeight)
            let docHeight = scrollbarDocumentHeight(contentHeight: contentHeight, cellHeight: cellHeight, total: total, len: len)
            let row = scrollbarRowFromPosition(
                documentHeight: docHeight, visibleOriginY: offsetY,
                visibleHeight: contentHeight, cellHeight: cellHeight
            )
            try expectEqual(row, Int(offset), "Round-trip failed for offset=\(offset)")
        }
    }
}
