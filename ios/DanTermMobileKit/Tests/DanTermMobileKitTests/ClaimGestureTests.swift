// Behavioral tests for the grid the phone's claim gesture asks a pane to run at.
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

@Test("The claim gesture asks for the whole cells its surface can show")
func claimCarriesTheSurfaceNativeGrid() throws {
    // Intent: the request a claim sends names the grid the phone renders at its own
    // native cell metrics, not the grid the Mac is running.
    // Why it exists: a claim that carried anything else would either keep the pane
    // unreadable or ask for a grid the phone cannot draw without scaling.
    // Scenario: a 1170x1800 pixel surface with a 14x30 pixel cell.
    let grid = try #require(MobileSurfaceGrid(
        widthPixels: 1170,
        heightPixels: 1800,
        cellWidthPixels: 14,
        cellHeightPixels: 30
    ))
    #expect(grid.columns == 83)
    #expect(grid.rows == 60)
    #expect(grid.claimRequest(for: paneId(7)) == .paneResize(
        pane: paneId(7),
        resize: .grid(columns: 83, rows: 60)
    ))
}

@Test("A partial trailing cell is not claimed")
func claimTruncatesToWholeCells() throws {
    let grid = try #require(MobileSurfaceGrid(
        widthPixels: 41,
        heightPixels: 61,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    ))
    #expect(grid.columns == 4)
    #expect(grid.rows == 3)
}

@Test("A surface with no room for a whole cell claims nothing")
func claimNeedsAtLeastOneCell() {
    #expect(MobileSurfaceGrid(
        widthPixels: 9,
        heightPixels: 100,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    ) == nil)
    #expect(MobileSurfaceGrid(
        widthPixels: 100,
        heightPixels: 19,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    ) == nil)
    #expect(MobileSurfaceGrid(
        widthPixels: 100,
        heightPixels: 100,
        cellWidthPixels: 0,
        cellHeightPixels: 20
    ) == nil)
}

private func paneId(_ value: Int) -> PaneId {
    PaneId(rawValue: UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", value))!)
}
