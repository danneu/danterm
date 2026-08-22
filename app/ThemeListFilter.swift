// Shared theme-name filtering for AppKit theme lists. Selection and interaction
// stay with each owning surface.
import Foundation

/// Keeps the browser and picker on one ordered, case-insensitive query rule.
func filteredThemeNames(_ catalog: [String], query: String) -> [String] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !normalizedQuery.isEmpty else { return catalog }
    return catalog.filter { $0.lowercased().contains(normalizedQuery) }
}
