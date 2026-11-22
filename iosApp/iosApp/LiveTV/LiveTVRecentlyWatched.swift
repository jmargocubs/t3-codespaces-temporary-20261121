import Foundation

/// A deliberately small persisted identity. Presentation data is always resolved from the current
/// provider catalog; stream URLs, names, logos and credentials never enter this record.
struct LiveTVRecentChannel: Codable, Hashable, Identifiable, Sendable {
    let providerID: UUID
    let channelID: String

    var id: String { "\(providerID.uuidString):\(channelID)" }

    init?(providerID: UUID, channelID: String) {
        guard Self.belongs(channelID, to: providerID) else { return nil }
        self.providerID = providerID
        self.channelID = channelID
    }

    static func belongs(_ channelID: String, to providerID: UUID) -> Bool {
        channelID.hasPrefix("\(providerID.uuidString):")
    }
}

enum LiveTVRecentHistory {
    static let capacity = 15

    /// Side-effect-free gate shared by the playing-ready callback and regression tests. A callback
    /// is recordable only while its generation/channel is still active and both provider and
    /// channel remain in the current catalog snapshot.
    static func playingReadyEntry(channelID: String, generation: Int, currentGeneration: Int,
                                  activeChannelID: String?, isPlaying: Bool,
                                  providerIsPresent: Bool, validChannelIDs: Set<String>) -> LiveTVRecentChannel? {
        guard generation == currentGeneration, activeChannelID == channelID, isPlaying,
              let providerID = UUID(uuidString: String(channelID.prefix(36))),
              providerIsPresent, validChannelIDs.contains(channelID) else { return nil }
        return LiveTVRecentChannel(providerID: providerID, channelID: channelID)
    }

    static func inserting(_ channel: LiveTVRecentChannel, into records: [LiveTVRecentChannel]) -> [LiveTVRecentChannel] {
        ([channel] + records.filter { $0 != channel }).prefix(capacity).map { $0 }
    }

    static func channels(in records: [LiveTVRecentChannel], providerID: UUID,
                         catalog: [LiveTVChannel]) -> [LiveTVChannel] {
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            guard record.providerID == providerID,
                  LiveTVRecentChannel.belongs(record.channelID, to: providerID) else { return nil }
            return byID[record.channelID]
        }
    }

    static func pruning(_ records: [LiveTVRecentChannel], providerID: UUID,
                        validChannelIDs: Set<String>) -> [LiveTVRecentChannel] {
        records.filter { $0.providerID != providerID || validChannelIDs.contains($0.channelID) }
    }
}

/// Bounded Home selections built from one provider snapshot. The resolver is intentionally
/// separate from SwiftUI so it can run off-main and be tested with catalog replacements.
enum LiveTVHomeChannelPreview {
    struct Result: Equatable, Sendable {
        let favorites: [LiveTVChannel]
        let recents: [LiveTVChannel]

        static let empty = Result(favorites: [], recents: [])
    }

    static func resolve(catalog: [LiveTVChannel], favoriteIDs: Set<String>,
                        recentRecords: [LiveTVRecentChannel], providerID: UUID,
                        favoriteLimit: Int = 12, recentLimit: Int = 10) -> Result {
        let records = recentRecords.filter { $0.providerID == providerID && LiveTVRecentChannel.belongs($0.channelID, to: providerID) }
            .prefix(LiveTVRecentHistory.capacity)
        let recentIDs = Set(records.map(\.channelID))
        let scopedFavorites = Set(favoriteIDs.filter { LiveTVRecentChannel.belongs($0, to: providerID) })
        guard !scopedFavorites.isEmpty || !recentIDs.isEmpty else { return Result(favorites: [], recents: []) }
        var favorites: [LiveTVChannel] = []
        var recentByID: [String: LiveTVChannel] = [:]
        for (index, channel) in catalog.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return Result(favorites: [], recents: []) }
            guard LiveTVRecentChannel.belongs(channel.id, to: providerID) else { continue }
            if favorites.count < max(0, favoriteLimit), scopedFavorites.contains(channel.id) { favorites.append(channel) }
            if recentIDs.contains(channel.id) { recentByID[channel.id] = channel }
            if favorites.count >= max(0, favoriteLimit), recentByID.count == recentIDs.count { break }
        }
        let recents = records.compactMap { recentByID[$0.channelID] }.prefix(max(0, recentLimit))
        return Result(favorites: favorites, recents: Array(recents))
    }
}

/// UserDefaults persistence is serialized away from playback callbacks. Every write replaces the
/// bounded snapshot, so queued writes stay ordered and cannot retain an unbounded event log.
final class LiveTVRecentHistoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let queue = DispatchQueue(label: "com.cubbiestream.kyro.live-tv-recents")

    init(defaults: UserDefaults = .standard, key: String = "liveTV.recently-watched.v1") {
        self.defaults = defaults
        self.key = key
    }

    func read() -> [LiveTVRecentChannel] {
        queue.sync {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([LiveTVRecentChannel].self, from: data) else { return [] }
            var seen = Set<LiveTVRecentChannel>()
            return decoded.filter { record in
                guard seen.insert(record).inserted,
                      LiveTVRecentChannel.belongs(record.channelID, to: record.providerID) else { return false }
                return true
            }.prefix(LiveTVRecentHistory.capacity).map { $0 }
        }
    }

    func save(_ records: [LiveTVRecentChannel]) {
        let bounded = Array(records.prefix(LiveTVRecentHistory.capacity))
        queue.async { [defaults, key] in
            guard let data = try? JSONEncoder().encode(bounded) else { return }
            defaults.set(data, forKey: key)
        }
    }

    /// Test/support synchronization only; never called by playback.
    func flush() { queue.sync {} }
}
