import Foundation
import SwiftUI

/// Stable scroll targets for the guide's category picker. The all-categories row is distinct from
/// any provider category with the same display text.
enum LiveTVGuideCategoryPickerID: Hashable, Sendable {
    case allCategories
    case category(String)
}

/// Keeps the last visible picker row independently for each provider. This is view state only; it
/// never participates in channel filtering or guide row construction.
struct LiveTVGuideCategoryPickerState {
    private var lastVisibleByProvider: [UUID: LiveTVGuideCategoryPickerID] = [:]

    func target(providerID: UUID, selectedCategory: String?, categories: [String]) -> LiveTVGuideCategoryPickerID {
        let valid = Set(categories.map(LiveTVGuideCategoryPickerID.category))
        if let lastVisible = lastVisibleByProvider[providerID],
           lastVisible == .allCategories || valid.contains(lastVisible) {
            return lastVisible
        }
        if let selectedCategory {
            let selected = LiveTVGuideCategoryPickerID.category(selectedCategory)
            if valid.contains(selected) { return selected }
        }
        return .allCategories
    }

    mutating func remember(_ id: LiveTVGuideCategoryPickerID?, providerID: UUID, categories: [String]) {
        guard let id else { return }
        let valid = Set(categories.map(LiveTVGuideCategoryPickerID.category))
        guard id == .allCategories || valid.contains(id) else { return }
        lastVisibleByProvider[providerID] = id
    }

    mutating func reconcile(providerID: UUID, categories: [String]) {
        guard let lastVisible = lastVisibleByProvider[providerID], lastVisible != .allCategories else { return }
        let valid = Set(categories.map(LiveTVGuideCategoryPickerID.category))
        if !valid.contains(lastVisible) { lastVisibleByProvider[providerID] = nil }
    }
}

/// Pure presentation data for the category picker. The picker owns no filter state; it only
/// derives searchable and frequently-used groups from the guide's existing catalog.
enum LiveTVGuideCategoryPickerModel {
    static func filteredCategories(_ categories: [String], query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return categories }
        return categories.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    static func frequentCategories(categories: [String], channels: [LiveTVChannel], favoriteIDs: Set<String>, limit: Int = 4) -> [String] {
        guard limit > 0 else { return [] }
        let valid = Set(categories)
        var counts: [String: Int] = [:]
        var favoriteCounts: [String: Int] = [:]
        for channel in channels where valid.contains(channel.category) {
            counts[channel.category, default: 0] += 1
            if favoriteIDs.contains(channel.id) { favoriteCounts[channel.category, default: 0] += 1 }
        }
        return categories.enumerated()
            .sorted {
                let lhs = (favoriteCounts[$0.element, default: 0], counts[$0.element, default: 0])
                let rhs = (favoriteCounts[$1.element, default: 0], counts[$1.element, default: 0])
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }
            .prefix(limit)
            .map(\.element)
    }

    /// The rows the picker shows, derived once per render. `frequent` is ranked once
    /// per picker presentation, so filtering never rescans the channel catalog.
    struct Projection: Equatable {
        let frequent: [String]
        let remaining: [String]
    }

    static func projection(categories: [String], query: String, frequent: [String]) -> Projection {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shownFrequent = isSearching ? [] : frequent
        let excluded = Set(shownFrequent)
        let filtered = filteredCategories(categories, query: query)
        return Projection(frequent: shownFrequent,
                          remaining: excluded.isEmpty ? filtered : filtered.filter { !excluded.contains($0) })
    }
}

