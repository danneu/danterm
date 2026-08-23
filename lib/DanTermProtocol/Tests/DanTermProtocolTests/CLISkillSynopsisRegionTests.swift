// Behavioral coverage for the generated command synopsis embedded in the DanTerm skill.
import Testing
@testable import DanTermProtocol

@Suite struct CLISkillSynopsisRegionTests {
    @Test("the checked-in generated region matches the command catalog")
    func matchingRegionPasses() throws {
        let document = "before\n\(CLISkillSynopsisRegion.beginMarker)\n\(CLISkillSynopsisRegion.contents)\n\(CLISkillSynopsisRegion.endMarker)\nafter\n"

        try CLISkillSynopsisRegion.check(document)
    }

    @Test("a stale generated region fails")
    func staleRegionFails() {
        let document = "before\n\(CLISkillSynopsisRegion.beginMarker)\n    danterm stale\n\(CLISkillSynopsisRegion.endMarker)\nafter\n"

        #expect(throws: CLISkillSynopsisRegionError.stale) {
            try CLISkillSynopsisRegion.check(document)
        }
    }

    @Test("missing and duplicate markers fail distinctly")
    func invalidMarkerCountsFail() {
        #expect(throws: CLISkillSynopsisRegionError.missingBeginMarker) {
            try CLISkillSynopsisRegion.update("before\n\(CLISkillSynopsisRegion.endMarker)\nafter\n")
        }
        #expect(throws: CLISkillSynopsisRegionError.missingEndMarker) {
            try CLISkillSynopsisRegion.update("before\n\(CLISkillSynopsisRegion.beginMarker)\nafter\n")
        }
        #expect(throws: CLISkillSynopsisRegionError.duplicateBeginMarker) {
            try CLISkillSynopsisRegion.update("\(CLISkillSynopsisRegion.beginMarker)\n\(CLISkillSynopsisRegion.beginMarker)\n\(CLISkillSynopsisRegion.endMarker)\n")
        }
        #expect(throws: CLISkillSynopsisRegionError.duplicateEndMarker) {
            try CLISkillSynopsisRegion.update("\(CLISkillSynopsisRegion.beginMarker)\n\(CLISkillSynopsisRegion.endMarker)\n\(CLISkillSynopsisRegion.endMarker)\n")
        }
    }

    @Test("reversed markers fail")
    func reversedMarkersFail() {
        let document = "\(CLISkillSynopsisRegion.endMarker)\n\(CLISkillSynopsisRegion.beginMarker)\n"

        #expect(throws: CLISkillSynopsisRegionError.reversedMarkers) {
            try CLISkillSynopsisRegion.update(document)
        }
    }

    @Test("updating preserves every byte outside the markers")
    func updatePreservesAuthoredBytes() throws {
        let prefix = "front matter\nprose with trailing spaces  \n\(CLISkillSynopsisRegion.beginMarker)"
        let suffix = "\(CLISkillSynopsisRegion.endMarker)\nmore prose\n"
        let document = "\(prefix)\nold contents\n\(suffix)"

        let updated = try CLISkillSynopsisRegion.update(document)

        #expect(updated == "\(prefix)\n\(CLISkillSynopsisRegion.contents)\n\(suffix)")
    }

    @Test("the synopsis includes canonical commands and aliases")
    func synopsisIncludesCatalogSpellings() {
        #expect(CLISkillSynopsisRegion.contents.contains("    danterm pane split (--pane <pane-id> -h|-v | --tab <tab-id>)"))
        #expect(CLISkillSynopsisRegion.contents.contains("    danterm help (aliases: danterm --help, danterm -h)"))
        #expect(CLISkillSynopsisRegion.contents.split(separator: "\n").count == CLICommandCatalog.entries.count)
    }
}
