// Behavioral tests for the comparison-grid geometry used by GlyphPreview.
import Testing

@testable import GlyphPreview

struct GlyphPreviewLayoutTests {
    @Test("An 80-column grid places section headings above 20 comparison tiles per band")
    func sectionBands() throws {
        let layout = try #require(GlyphPreviewLayout(
            columns: 80,
            sectionGlyphCounts: [128, 32]
        ))

        #expect(layout.glyphsPerBand == 20)
        #expect(layout.rows == 20)
        #expect(layout.sections[0].headingRow == 0)
        #expect(layout.sections[0].origin(forGlyphAt: 0) == GlyphPreviewPosition(column: 0, row: 1))
        #expect(layout.sections[0].origin(forGlyphAt: 19) == GlyphPreviewPosition(column: 76, row: 1))
        #expect(layout.sections[0].origin(forGlyphAt: 20) == GlyphPreviewPosition(column: 0, row: 3))
        #expect(layout.sections[1].headingRow == 15)
        #expect(layout.sections[1].origin(forGlyphAt: 0) == GlyphPreviewPosition(column: 0, row: 16))
    }

    @Test("Comparison grids reject widths that cannot hold one four-column tile")
    func rejectsNarrowGrid() {
        #expect(GlyphPreviewLayout(columns: 3, sectionGlyphCounts: [1]) == nil)
        #expect(GlyphPreviewLayout(columns: 80, sectionGlyphCounts: [-1]) == nil)
    }

    @Test("Preview corpus mirrors every checklist section and codepoint")
    func checklistCorpus() {
        #expect(glyphPreviewSections.map(\.title) == [
            "Box Drawing",
            "Block Elements",
            "Geometric Shapes",
            "Braille Patterns",
            "Powerline private-use glyphs",
            "Branch Drawing private-use glyphs",
            "Symbols for Legacy Computing",
            "Symbols for Legacy Computing Supplement",
        ])
        #expect(glyphPreviewSections.map(\.scalars.count) == [
            128, 32, 8, 256, 18, 62, 213, 368,
        ])
        #expect(glyphPreviewSections.flatMap(\.scalars).count == 1_085)
    }
}
