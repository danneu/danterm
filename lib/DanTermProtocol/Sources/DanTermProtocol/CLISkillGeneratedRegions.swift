// Projects protocol declarations into the named generated regions in the DanTerm skill.

/// Identifies one generated part of the skill and owns its markers and current contents.
public enum CLISkillGeneratedRegion: CaseIterable, Sendable {
    /// Lists every public command and alias from the command catalog.
    case commandSynopsis
    /// Lists the protocol values that explanatory prose needs to cite.
    case protocolConstants

    /// Names the region in diagnostics.
    public var name: String {
        switch self {
        case .commandSynopsis: "command synopsis"
        case .protocolConstants: "protocol constants"
        }
    }

    /// Starts the bytes the repository generator owns for this region.
    public var beginMarker: String {
        switch self {
        case .commandSynopsis: "<!-- BEGIN GENERATED DANTERM COMMAND SYNOPSIS -->"
        case .protocolConstants: "<!-- BEGIN GENERATED DANTERM PROTOCOL CONSTANTS -->"
        }
    }

    /// Ends the bytes the repository generator owns for this region.
    public var endMarker: String {
        switch self {
        case .commandSynopsis: "<!-- END GENERATED DANTERM COMMAND SYNOPSIS -->"
        case .protocolConstants: "<!-- END GENERATED DANTERM PROTOCOL CONSTANTS -->"
        }
    }

    /// Renders the current declarations in the region's documented form.
    public var contents: String {
        switch self {
        case .commandSynopsis:
            CLICommandCatalog.entries.map { entry in
                let canonical = "    danterm \(entry.synopsis)"
                guard entry.aliases.isEmpty == false else { return canonical }
                let aliases = entry.aliases
                    .map { "danterm \($0.joined(separator: " "))" }
                    .joined(separator: ", ")
                return "\(canonical) (aliases: \(aliases))"
            }.joined(separator: "\n")
        case .protocolConstants:
            """
            | Declaration | Value |
            |---|---|
            | `paneTapeStreamVersion` | `\(paneTapeStreamVersion)` |
            | `PaneTapeSyncPolicy.defaultHistoryBudgetBytes` | `\(PaneTapeSyncPolicy.defaultHistoryBudgetBytes)` bytes |
            | `paneGridOverrideColumnRange` | `\(paneGridOverrideColumnRange.lowerBound)...\(paneGridOverrideColumnRange.upperBound)` |
            | `paneGridOverrideRowRange` | `\(paneGridOverrideRowRange.lowerBound)...\(paneGridOverrideRowRange.upperBound)` |
            """
        }
    }
}

/// Identifies a malformed or stale generated skill region.
public enum CLISkillGeneratedRegionError: Error, Equatable, CustomStringConvertible {
    /// The document has no opening marker for the named region.
    case missingBeginMarker(CLISkillGeneratedRegion)
    /// The document has no closing marker for the named region.
    case missingEndMarker(CLISkillGeneratedRegion)
    /// The document has more than one opening marker for the named region.
    case duplicateBeginMarker(CLISkillGeneratedRegion)
    /// The document has more than one closing marker for the named region.
    case duplicateEndMarker(CLISkillGeneratedRegion)
    /// The named region's closing marker appears before its opening marker.
    case reversedMarkers(CLISkillGeneratedRegion)
    /// The named region does not match its current declaration projection.
    case stale(CLISkillGeneratedRegion)

    /// Names the region and the repair needed when the generator rejects a document.
    public var description: String {
        switch self {
        case .missingBeginMarker(let region): "\(region.name): missing generated region begin marker"
        case .missingEndMarker(let region): "\(region.name): missing generated region end marker"
        case .duplicateBeginMarker(let region): "\(region.name): duplicate generated region begin marker"
        case .duplicateEndMarker(let region): "\(region.name): duplicate generated region end marker"
        case .reversedMarkers(let region): "\(region.name): generated region markers are reversed"
        case .stale(let region): "\(region.name): generated region is stale"
        }
    }
}

/// Checks or updates the complete set of generated skill regions as one document contract.
public enum CLISkillGeneratedRegions {
    /// Replaces only the bytes between each region's unique, ordered markers.
    public static func update(_ document: String) throws -> String {
        try CLISkillGeneratedRegion.allCases.reduce(document) { updated, region in
            try update(region, in: updated)
        }
    }

    /// Rejects the first malformed or stale region and names it in the error.
    public static func check(_ document: String) throws {
        for region in CLISkillGeneratedRegion.allCases {
            guard try update(region, in: document) == document else {
                throw CLISkillGeneratedRegionError.stale(region)
            }
        }
    }

    private static func update(
        _ region: CLISkillGeneratedRegion,
        in document: String
    ) throws -> String {
        let begin = try uniqueRange(of: region.beginMarker, for: region, in: document, begin: true)
        let end = try uniqueRange(of: region.endMarker, for: region, in: document, begin: false)
        guard begin.upperBound <= end.lowerBound else {
            throw CLISkillGeneratedRegionError.reversedMarkers(region)
        }

        var updated = document
        updated.replaceSubrange(begin.upperBound..<end.lowerBound, with: "\n\(region.contents)\n")
        return updated
    }

    private static func uniqueRange(
        of marker: String,
        for region: CLISkillGeneratedRegion,
        in document: String,
        begin: Bool
    ) throws -> Range<String.Index> {
        let count = document.components(separatedBy: marker).count - 1
        guard count > 0 else {
            throw begin
                ? CLISkillGeneratedRegionError.missingBeginMarker(region)
                : CLISkillGeneratedRegionError.missingEndMarker(region)
        }
        guard count == 1 else {
            throw begin
                ? CLISkillGeneratedRegionError.duplicateBeginMarker(region)
                : CLISkillGeneratedRegionError.duplicateEndMarker(region)
        }
        return document.range(of: marker)!
    }
}
