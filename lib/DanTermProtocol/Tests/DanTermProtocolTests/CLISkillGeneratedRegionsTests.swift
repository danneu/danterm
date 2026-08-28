// Behavioral coverage for every generated region embedded in the DanTerm skill.
import Foundation
import Testing
@testable import DanTermProtocol

@Suite struct CLISkillGeneratedRegionsTests {
    @Test("the checked-in generated regions match their declarations")
    func matchingRegionsPass() throws {
        try CLISkillGeneratedRegions.check(generatedDocument())
    }

    @Test("each stale generated region fails with its name", arguments: CLISkillGeneratedRegion.allCases)
    func staleRegionFails(region: CLISkillGeneratedRegion) {
        let document = generatedDocument().replacingOccurrences(of: region.contents, with: "stale")

        let error = #expect(throws: CLISkillGeneratedRegionError.self) {
            try CLISkillGeneratedRegions.check(document)
        }
        #expect(error?.description.contains(region.name) == true)
    }

    @Test("each region reports missing and duplicate markers with its name", arguments: CLISkillGeneratedRegion.allCases)
    func invalidMarkerCountsFail(region: CLISkillGeneratedRegion) {
        let document = generatedDocument()
        let missingBegin = document.replacingOccurrences(of: region.beginMarker, with: "")
        let missingEnd = document.replacingOccurrences(of: region.endMarker, with: "")
        let duplicateBegin = document.replacingOccurrences(
            of: region.beginMarker,
            with: "\(region.beginMarker)\n\(region.beginMarker)"
        )
        let duplicateEnd = document.replacingOccurrences(
            of: region.endMarker,
            with: "\(region.endMarker)\n\(region.endMarker)"
        )

        for malformed in [missingBegin, missingEnd, duplicateBegin, duplicateEnd] {
            let error = #expect(throws: CLISkillGeneratedRegionError.self) {
                try CLISkillGeneratedRegions.update(malformed)
            }
            #expect(error?.description.contains(region.name) == true)
        }
    }

    @Test("each region reports reversed markers with its name", arguments: CLISkillGeneratedRegion.allCases)
    func reversedMarkersFail(region: CLISkillGeneratedRegion) {
        let document = generatedDocument()
            .replacingOccurrences(of: region.beginMarker, with: "TEMP MARKER")
            .replacingOccurrences(of: region.endMarker, with: region.beginMarker)
            .replacingOccurrences(of: "TEMP MARKER", with: region.endMarker)

        let error = #expect(throws: CLISkillGeneratedRegionError.self) {
            try CLISkillGeneratedRegions.update(document)
        }
        #expect(error?.description.contains(region.name) == true)
    }

    @Test("updating preserves every byte outside all markers")
    func updatePreservesAuthoredBytes() throws {
        let prefix = "front matter\nprose with trailing spaces  "
        let suffix = "more prose\n"
        let staleRegions = CLISkillGeneratedRegion.allCases.map {
            "\($0.beginMarker)\nold \($0.name) contents\n\($0.endMarker)"
        }.joined(separator: "\nauthored bridge\n")

        let updated = try CLISkillGeneratedRegions.update("\(prefix)\n\(staleRegions)\n\(suffix)")

        #expect(updated.hasPrefix("\(prefix)\n"))
        #expect(updated.hasSuffix("\n\(suffix)"))
        #expect(updated.contains("\nauthored bridge\n"))
        for region in CLISkillGeneratedRegion.allCases {
            #expect(updated.contains("\(region.beginMarker)\n\(region.contents)\n\(region.endMarker)"))
        }
    }

    @Test("the synopsis includes canonical commands and aliases")
    func synopsisIncludesCatalogSpellings() {
        let contents = CLISkillGeneratedRegion.commandSynopsis.contents

        #expect(contents.contains("    danterm pane split (--pane <pane-id> -h|-v | --tab <tab-id>)"))
        #expect(contents.contains("    danterm help (aliases: danterm --help, danterm -h)"))
        #expect(contents.split(separator: "\n").count == CLICommandCatalog.entries.count)
    }

    @Test("the protocol constants region renders every shared declaration")
    func constantsRegionIncludesSharedDeclarations() {
        let contents = CLISkillGeneratedRegion.protocolConstants.contents

        #expect(contents.contains("`paneTapeStreamVersion` | `\(paneTapeStreamVersion)`"))
        #expect(contents.contains("`PaneTapeSyncPolicy.defaultHistoryBudgetBytes` | `\(PaneTapeSyncPolicy.defaultHistoryBudgetBytes)` bytes"))
        #expect(contents.contains("`paneGridOverrideColumnRange` | `\(paneGridOverrideColumnRange.lowerBound)...\(paneGridOverrideColumnRange.upperBound)`"))
        #expect(contents.contains("`paneGridOverrideRowRange` | `\(paneGridOverrideRowRange.lowerBound)...\(paneGridOverrideRowRange.upperBound)`"))
    }

    @Test("the stdout region projects every catalog output and omits silent commands")
    func stdoutRegionProjectsCatalogContracts() {
        let contents = CLISkillGeneratedRegion.stdoutShapes.contents

        #expect(contents.contains("`doctor`"))
        #expect(contents.contains("`help`"))
        #expect(contents.contains("`skill`"))
        #expect(contents.contains("`pane tape --pane <pane-id> ... --format replay`"))
        #expect(contents.contains("`pane tape --pane <pane-id> ... --format inspect`"))
        #expect(contents.contains("pane split (--pane <pane-id> -h\\|-v \\| --tab <tab-id>)"))
        #expect(contents.contains("on\\|off\\|toggle"))
        #expect(contents.contains("`quit` |") == false)
        let renderedRowCount = contents.split(separator: "\n").count - 2
        let declaredRowCount = CLICommandCatalog.entries
            .flatMap(\.output.forms)
            .filter { $0.kind != .none }
            .count
        #expect(renderedRowCount == declaredRowCount)
        for row in contents.split(separator: "\n") {
            let delimiters = row.replacingOccurrences(of: "\\|", with: "")
                .filter { $0 == "|" }
                .count
            #expect(delimiters == 3, "malformed Markdown table row: \(row)")
        }
    }

    @Test("the checked-in prose refers to generated protocol constants instead of copying them")
    func checkedInProseDoesNotCopyProtocolConstants() throws {
        let skill = try String(contentsOf: repositoryRoot.appending(path: "integrations/danterm/SKILL.md"), encoding: .utf8)
        let authored = try removingGeneratedContents(from: skill)

        #expect(authored.components(separatedBy: "[CLI protocol constants](#cli-protocol-constants)").count - 1 == 4)
        #expect(authored.contains("2 through 1024") == false)
        #expect(authored.contains("at most 262144") == false)
        #expect(authored.contains("\"version\":6") == false)
        #expect(authored.contains("\"version\":3") == false)
    }
}

private func generatedDocument() -> String {
    CLISkillGeneratedRegion.allCases.map {
        "\($0.beginMarker)\n\($0.contents)\n\($0.endMarker)"
    }.joined(separator: "\nauthored bridge\n")
}

private func removingGeneratedContents(from document: String) throws -> String {
    var authored = document
    for region in CLISkillGeneratedRegion.allCases {
        let begin = try #require(authored.range(of: region.beginMarker))
        let end = try #require(authored.range(of: region.endMarker))
        authored.replaceSubrange(begin.upperBound..<end.lowerBound, with: "")
    }
    return authored
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
