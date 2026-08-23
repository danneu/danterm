// Projects the public command catalog into the one generated region in the DanTerm skill.

/// Identifies a malformed or stale generated command synopsis region.
public enum CLISkillSynopsisRegionError: Error, Equatable, CustomStringConvertible {
    /// The document has no opening marker.
    case missingBeginMarker
    /// The document has no closing marker.
    case missingEndMarker
    /// The document has more than one opening marker.
    case duplicateBeginMarker
    /// The document has more than one closing marker.
    case duplicateEndMarker
    /// The closing marker appears before the opening marker.
    case reversedMarkers
    /// The marked region does not match the current catalog projection.
    case stale

    /// Explains the repair needed when the repository generator rejects a document.
    public var description: String {
        switch self {
        case .missingBeginMarker: "missing generated synopsis begin marker"
        case .missingEndMarker: "missing generated synopsis end marker"
        case .duplicateBeginMarker: "duplicate generated synopsis begin marker"
        case .duplicateEndMarker: "duplicate generated synopsis end marker"
        case .reversedMarkers: "generated synopsis markers are reversed"
        case .stale: "generated command synopsis is stale"
        }
    }
}

/// Owns the markers, rendering, and replacement rules for the skill's generated region.
public enum CLISkillSynopsisRegion {
    /// Starts the bytes that the repository generator owns.
    public static let beginMarker = "<!-- BEGIN GENERATED DANTERM COMMAND SYNOPSIS -->"
    /// Ends the bytes that the repository generator owns.
    public static let endMarker = "<!-- END GENERATED DANTERM COMMAND SYNOPSIS -->"

    /// Renders one exhaustive command line per catalog entry, including accepted aliases.
    public static var contents: String {
        CLICommandCatalog.entries.map { entry in
            let canonical = "    danterm \(entry.synopsis)"
            guard entry.aliases.isEmpty == false else { return canonical }
            let aliases = entry.aliases
                .map { "danterm \($0.joined(separator: " "))" }
                .joined(separator: ", ")
            return "\(canonical) (aliases: \(aliases))"
        }.joined(separator: "\n")
    }

    /// Replaces only the bytes between the document's unique, ordered markers.
    public static func update(_ document: String) throws -> String {
        let begin = try uniqueRange(of: beginMarker, in: document, begin: true)
        let end = try uniqueRange(of: endMarker, in: document, begin: false)
        guard begin.upperBound <= end.lowerBound else {
            throw CLISkillSynopsisRegionError.reversedMarkers
        }

        var updated = document
        updated.replaceSubrange(begin.upperBound..<end.lowerBound, with: "\n\(contents)\n")
        return updated
    }

    /// Rejects a malformed region or one whose checked-in bytes do not match the catalog.
    public static func check(_ document: String) throws {
        guard try update(document) == document else {
            throw CLISkillSynopsisRegionError.stale
        }
    }

    private static func uniqueRange(
        of marker: String,
        in document: String,
        begin: Bool
    ) throws -> Range<String.Index> {
        let count = document.components(separatedBy: marker).count - 1
        guard count > 0 else {
            throw begin
                ? CLISkillSynopsisRegionError.missingBeginMarker
                : CLISkillSynopsisRegionError.missingEndMarker
        }
        guard count == 1 else {
            throw begin
                ? CLISkillSynopsisRegionError.duplicateBeginMarker
                : CLISkillSynopsisRegionError.duplicateEndMarker
        }
        return document.range(of: marker)!
    }
}
