#if os(iOS)
import Foundation
import Observation

/// Bounded iOS projection of one provider catalog query. It retains only pages the viewer has
/// reached and cancels stale work when provider, catalog generation, or filters change.
@MainActor
@Observable
final class LiveTVPagedChannelModel {
    static let pageSize = 200
    static let maximumRetainedChannels = 1_000

    private(set) var channels: [LiveTVChannel] = []
    private(set) var totalCount = 0
    private(set) var isLoading = false
    private(set) var hasMoreBefore = false
    private(set) var hasMoreAfter = false

    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var identity: Identity?
    @ObservationIgnored private var startOffset = 0

    struct Identity: Equatable, Sendable {
        let providerID: UUID
        let catalogRevision: Int
        let query: String
        let category: String?
        let favoritesOnly: Bool
        let favoritesSignature: Int
    }

    var resultCount: Int { totalCount }

    var groups: [String: [LiveTVChannel]] {
        Dictionary(grouping: channels, by: \LiveTVChannel.category)
    }

    var orderedCategories: [String] {
        var seen = Set<String>()
        return channels.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    func reset(service: LiveTVService, providerID: UUID?, catalogRevision: Int,
               query: String, category: String?, favoritesOnly: Bool) {
        guard let providerID else {
            request?.cancel()
            request = nil
            identity = nil
            channels = []
            totalCount = 0
            hasMoreBefore = false
            hasMoreAfter = false
            startOffset = 0
            isLoading = false
            return
        }
        let next = Identity(providerID: providerID, catalogRevision: catalogRevision,
                            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category, favoritesOnly: favoritesOnly,
                            favoritesSignature: service.favoriteChannelIDs.hashValue)
        // SwiftUI can call updateSearch from both the home tab and its pushed destination.
        // A repeated update for the same query must not cancel the in-flight request: doing so
        // left `isLoading` true forever because the cancelled task correctly refused publication.
        guard next != identity else { return }
        request?.cancel()
        identity = next
        isLoading = true
        request = Task { [weak self, weak service] in
            guard let self, let service else { return }
            if !next.query.isEmpty {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
            }
            async let page = service.channelPage(providerID: next.providerID, query: next.query,
                                                  category: next.category,
                                                  favoritesOnly: next.favoritesOnly,
                                                  offset: 0, limit: Self.pageSize)
            async let count = service.channelCount(providerID: next.providerID, query: next.query,
                                                    category: next.category,
                                                    favoritesOnly: next.favoritesOnly)
            let (loaded, total) = await (page, count)
            guard !Task.isCancelled, self.identity == next,
                  service.selectedProviderID == next.providerID,
                  service.channelCatalogRevision == next.catalogRevision else { return }
            self.channels = loaded
            self.totalCount = total
            self.startOffset = 0
            self.hasMoreBefore = false
            self.hasMoreAfter = loaded.count < total
            self.isLoading = false
        }
    }

    func loadPageIfNeeded(around channel: LiveTVChannel, service: LiveTVService) {
        if channels.last?.id == channel.id, hasMoreAfter {
            loadNext(service: service)
        } else if channels.first?.id == channel.id, hasMoreBefore {
            loadPrevious(service: service)
        }
    }

    /// Repositions the bounded window around a stable channel identity. The store computes the
    /// channel's offset under the current filters, so restoration does not walk every preceding
    /// page and remains valid when a refreshed generation moves the channel.
    @discardableResult
    func restoreAnchor(channelID: String, service: LiveTVService) async -> Bool {
        guard let identity else { return false }
        let expected = identity
        guard let anchorOffset = await service.channelOffset(
            providerID: identity.providerID, channelID: channelID, query: identity.query,
            category: identity.category, favoritesOnly: identity.favoritesOnly
        ) else { return false }
        let offset = max(0, anchorOffset - Self.pageSize / 2)
        let loaded = await service.channelPage(providerID: identity.providerID, query: identity.query,
                                               category: identity.category,
                                               favoritesOnly: identity.favoritesOnly,
                                               offset: offset, limit: Self.pageSize)
        guard !Task.isCancelled, self.identity == expected,
              service.selectedProviderID == expected.providerID,
              service.channelCatalogRevision == expected.catalogRevision,
              loaded.contains(where: { $0.id == channelID }) else { return false }
        channels = loaded
        startOffset = offset
        hasMoreBefore = offset > 0
        hasMoreAfter = offset + loaded.count < totalCount
        isLoading = false
        return true
    }

    private func loadNext(service: LiveTVService) {
        guard hasMoreAfter, !isLoading, let identity else { return }
        isLoading = true
        let offset = startOffset + channels.count
        request = Task { [weak self, weak service] in
            guard let self, let service else { return }
            let loaded = await service.channelPage(providerID: identity.providerID, query: identity.query,
                                                   category: identity.category,
                                                   favoritesOnly: identity.favoritesOnly,
                                                   offset: offset, limit: Self.pageSize)
            guard !Task.isCancelled, self.identity == identity,
                  service.selectedProviderID == identity.providerID,
                  service.channelCatalogRevision == identity.catalogRevision else { return }
            var known = Set(self.channels.map(\LiveTVChannel.id))
            self.channels.append(contentsOf: loaded.filter { known.insert($0.id).inserted })
            if self.channels.count > Self.maximumRetainedChannels {
                let removed = self.channels.count - Self.maximumRetainedChannels
                self.channels.removeFirst(removed)
                self.startOffset += removed
            }
            self.hasMoreBefore = self.startOffset > 0
            self.hasMoreAfter = self.startOffset + self.channels.count < self.totalCount && !loaded.isEmpty
            self.isLoading = false
        }
    }

    private func loadPrevious(service: LiveTVService) {
        guard hasMoreBefore, !isLoading, let identity else { return }
        isLoading = true
        let offset = max(0, startOffset - Self.pageSize)
        let limit = startOffset - offset
        request = Task { [weak self, weak service] in
            guard let self, let service else { return }
            let loaded = await service.channelPage(providerID: identity.providerID, query: identity.query,
                                                   category: identity.category,
                                                   favoritesOnly: identity.favoritesOnly,
                                                   offset: offset, limit: limit)
            guard !Task.isCancelled, self.identity == identity,
                  service.selectedProviderID == identity.providerID,
                  service.channelCatalogRevision == identity.catalogRevision else { return }
            var known = Set(self.channels.map(\LiveTVChannel.id))
            self.channels.insert(contentsOf: loaded.filter { known.insert($0.id).inserted }, at: 0)
            self.startOffset = offset
            if self.channels.count > Self.maximumRetainedChannels {
                self.channels.removeLast(self.channels.count - Self.maximumRetainedChannels)
            }
            self.hasMoreBefore = self.startOffset > 0 && !loaded.isEmpty
            self.hasMoreAfter = self.startOffset + self.channels.count < self.totalCount
            self.isLoading = false
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
        isLoading = false
    }

    func waitForCurrentQuery() async {
        await request?.value
    }
}
#endif
