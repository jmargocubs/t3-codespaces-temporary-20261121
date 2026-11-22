#if os(iOS)
import Foundation
import Observation

/// Bounded local VOD search. It never refreshes a provider or fetches episode details while typing.
@MainActor
@Observable
final class KyroVODSearchModel {
    enum Phase: Equatable { case idle, loading, complete, incomplete, unavailable }
    private(set) var phase: Phase = .idle
    private(set) var items: [XtreamVODItem] = []
    private(set) var completedQuery = ""
    private(set) var completedRevision = -1
    private(set) var completedProviderIDs: [UUID] = []
    private var requestTracker = VODSearchRequestTracker()
    private let service: XtreamVODService
    private let liveTV: LiveTVService

    init(service: XtreamVODService? = nil, liveTV: LiveTVService? = nil) {
        self.service = service ?? .shared
        self.liveTV = liveTV ?? .shared
    }

    /// Invalidates in-flight work without erasing a completed query when Search is merely
    /// dismissed. A query edit uses `clearResults: true` so old results cannot be mistaken
    /// for results belonging to the new text.
    func cancel(clearResults: Bool = false) {
        requestTracker.cancel()
        if clearResults {
            items = []
            phase = .idle
            completedQuery = ""
            completedRevision = -1
            completedProviderIDs = []
        } else if phase == .loading {
            phase = .idle
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = requestTracker.begin(trimmed)
        guard !trimmed.isEmpty else {
            items = []
            phase = .idle
            completedQuery = ""
            return
        }
        // Keep a still-current completed result set visible while the same query is
        // refreshed (for example, when the keyboard Search button is pressed).
        // Query edits already clear results in SearchView's binding setter.
        phase = .loading
        let revision = service.catalogRevision
        let providers = liveTV.providers.filter { $0.kind == .xtream }
        let providerIDs = providers.map(\.id)
        guard IPTVVODPreference.isEnabled(), !providers.isEmpty else {
            phase = .complete
            completedQuery = trimmed
            completedRevision = revision
            completedProviderIDs = providerIDs
            return
        }
        var found: [XtreamVODItem] = []
        var incomplete = false
        for provider in providers {
            if service.refreshedAt(providerID: provider.id) == nil { incomplete = true }
            for kind in XtreamVODKind.allCases {
                guard !Task.isCancelled, requestTracker.accepts(token, query: trimmed) else { return }
                // A provider-level refresh can succeed for only one kind. No active rows for the
                // other kind are not evidence that the title is absent.
                if await service.count(providerID: provider.id, kind: kind) == 0 { incomplete = true }
                guard !Task.isCancelled, requestTracker.accepts(token, query: trimmed) else { return }
                let page = await service.page(providerID: provider.id, kind: kind, query: trimmed)
                guard !Task.isCancelled, requestTracker.accepts(token, query: trimmed) else { return }
                found.append(contentsOf: page)
                // Store paging is capped at 100; don't claim a complete result set at that edge.
                if page.count == 100 { incomplete = true }
            }
        }
        guard revision == service.catalogRevision,
              providerIDs == liveTV.providers.filter({ $0.kind == .xtream }).map(\.id) else {
            phase = .incomplete
            return
        }
        items = found
        phase = incomplete ? .incomplete : .complete
        completedQuery = trimmed
        completedRevision = revision
        completedProviderIDs = providerIDs
    }

    func isCurrent(query: String) -> Bool {
        completedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) &&
        completedRevision == service.catalogRevision &&
        completedProviderIDs == liveTV.providers.filter { $0.kind == .xtream }.map(\.id)
    }
}
#endif
