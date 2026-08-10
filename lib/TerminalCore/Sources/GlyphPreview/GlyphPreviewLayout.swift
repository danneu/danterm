// Pure section corpus and comparison-grid geometry used by GlyphPreview.

/// Describes one checklist heading and the exact Unicode scalars it covers.
struct GlyphPreviewSection {
    let title: String
    let scalars: [Unicode.Scalar]
    let customSpriteScalars: Set<Unicode.Scalar>

    init(
        title: String,
        ranges: [ClosedRange<UInt32>],
        implementedRanges: [ClosedRange<UInt32>] = []
    ) {
        self.title = title
        self.scalars = Self.expand(ranges)
        self.customSpriteScalars = Set(Self.expand(implementedRanges))
    }

    private static func expand(_ ranges: [ClosedRange<UInt32>]) -> [Unicode.Scalar] {
        ranges.flatMap { range in
            range.compactMap(Unicode.Scalar.init)
        }
    }
}

let glyphPreviewSections = [
    GlyphPreviewSection(
        title: "Box Drawing",
        ranges: [0x2500...0x257F],
        implementedRanges: [0x2500...0x257F]
    ),
    GlyphPreviewSection(
        title: "Block Elements",
        ranges: [0x2580...0x259F],
        implementedRanges: [0x2580...0x259F]
    ),
    GlyphPreviewSection(
        title: "Geometric Shapes",
        ranges: [0x25E2...0x25E5, 0x25F8...0x25FA, 0x25FF...0x25FF],
        implementedRanges: [0x25E2...0x25E5, 0x25F8...0x25FA, 0x25FF...0x25FF]
    ),
    GlyphPreviewSection(
        title: "Braille Patterns",
        ranges: [0x2800...0x28FF],
        implementedRanges: [0x2800...0x28FF]
    ),
    GlyphPreviewSection(
        title: "Powerline private-use glyphs",
        ranges: [0xE0B0...0xE0BF, 0xE0D2...0xE0D2, 0xE0D4...0xE0D4],
        implementedRanges: [0xE0B0...0xE0BF, 0xE0D2...0xE0D2, 0xE0D4...0xE0D4]
    ),
    GlyphPreviewSection(
        title: "Branch Drawing private-use glyphs",
        ranges: [0xF5D0...0xF60D],
        implementedRanges: [0xF5D0...0xF60D]
    ),
    GlyphPreviewSection(
        title: "Symbols for Legacy Computing",
        ranges: [
            0x1FB00...0x1FB9F,
            0x1FBA0...0x1FBAF,
            0x1FBBD...0x1FBBF,
            0x1FBCE...0x1FBEF,
        ],
        implementedRanges: [
            0x1FB00...0x1FBAF,
            0x1FBBD...0x1FBBF,
            0x1FBCE...0x1FBEF,
        ]
    ),
    GlyphPreviewSection(
        title: "Symbols for Legacy Computing Supplement",
        ranges: [
            0x1CC1B...0x1CC1E,
            0x1CC21...0x1CC3F,
            0x1CD00...0x1CDE5,
            0x1CE00...0x1CE01,
            0x1CE0B...0x1CE0C,
            0x1CE16...0x1CE19,
            0x1CE51...0x1CEAF,
        ],
        implementedRanges: [
            0x1CC1B...0x1CC1E,
            0x1CC21...0x1CC3F,
            0x1CD00...0x1CDE5,
            0x1CE00...0x1CE01,
            0x1CE0B...0x1CE0C,
            0x1CE16...0x1CE19,
            0x1CE51...0x1CEAF,
        ]
    ),
]

/// Locates the top-left cell of one reference-and-sprite comparison tile.
struct GlyphPreviewPosition: Equatable {
    let column: Int
    let row: Int
}

/// Locates one heading and its following `aabb` / `aabb` tile bands.
struct GlyphPreviewSectionLayout {
    let headingRow: Int
    let contentRow: Int
    let glyphsPerBand: Int

    func origin(forGlyphAt index: Int) -> GlyphPreviewPosition {
        GlyphPreviewPosition(
            column: (index % glyphsPerBand) * GlyphPreviewLayout.tileColumns,
            row: contentRow + (index / glyphsPerBand) * GlyphPreviewLayout.tileRows
        )
    }
}

/// Packs headed comparison sections into a fixed-width terminal grid.
struct GlyphPreviewLayout {
    static let tileColumns = 4
    static let tileRows = 2

    let columns: Int
    let glyphsPerBand: Int
    let sections: [GlyphPreviewSectionLayout]
    let rows: Int

    init?(columns: Int, sectionGlyphCounts: [Int]) {
        guard columns >= Self.tileColumns,
              sectionGlyphCounts.allSatisfy({ $0 >= 0 })
        else {
            return nil
        }
        let glyphsPerBand = columns / Self.tileColumns
        var nextRow = 0
        var sections: [GlyphPreviewSectionLayout] = []
        sections.reserveCapacity(sectionGlyphCounts.count)
        for glyphCount in sectionGlyphCounts {
            sections.append(GlyphPreviewSectionLayout(
                headingRow: nextRow,
                contentRow: nextRow + 1,
                glyphsPerBand: glyphsPerBand
            ))
            let bands = glyphCount == 0 ? 0 : (glyphCount + glyphsPerBand - 1) / glyphsPerBand
            nextRow += 1 + bands * Self.tileRows
        }
        self.columns = columns
        self.glyphsPerBand = glyphsPerBand
        self.sections = sections
        self.rows = nextRow
    }
}
