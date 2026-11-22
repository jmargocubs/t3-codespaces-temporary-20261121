import Foundation

/// Backs the "Available to request" section embedded in the library
/// `SearchView`. Driven by the same query string the catalog search owns
/// (one text field, one debounce feel, two independent result sets and
/// failure domains — a requests-API error just hides this supplementary
/// section without touching the primary search).
@Observable
@MainActor
final class RequestSearchSectionViewModel {
    private(set) var results: [RequestMediaResult] = []
    private(set) var isLoading = false

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private let api: SiloAPI

    /// Cap the inline strip — it supplements library results, it doesn't
    /// replace the hub's full search.
    private let maxResults = 12

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func onQueryChanged(_ query: String) {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard RequestsFeatureStore.shared.isEnabled, trimmed.count > 1 else {
            results = []
            isLoading = false
            return
        }
        searchTask = Task {
            // Same 300ms debounce as `SearchViewModel` for a single feel.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(trimmed, generation: generation)
        }
    }

    /// Coordinator entry point: share its debounce with catalog and IPTV search instead of
    /// scheduling this supplementary lookup's independent delay a second time.
    func performCoordinatedSearch(_ query: String) async {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = nil
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard RequestsFeatureStore.shared.isEnabled, trimmed.count > 1 else {
            results = []
            isLoading = false
            return
        }
        await performSearch(trimmed, generation: generation)
    }

    /// A profile/server boundary cancels any outstanding discovery request and clears its
    /// profile-owned result state. It intentionally does not persist mixed search history.
    func resetForCoordinatedIdentityChange() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        results = []
        isLoading = false
    }

    private func performSearch(_ trimmed: String, generation: Int) async {
        isLoading = true
        // Cancellation paths must still clear the spinner: a replacement
        // search re-raises `isLoading` after its own 300ms debounce, so a
        // cancelled task's `false` can never stomp a successor's `true`.
        do {
            let page = try await api.requestsSearch(query: trimmed)
            guard !Task.isCancelled, generation == searchGeneration else {
                if generation == searchGeneration { isLoading = false }
                return
            }
            // Only titles the library can't already answer — in-library
            // matches are what the catalog grid above is for.
            results = page.results
                .filter { $0.availability != .available && $0.mediaType != .unknown }
                .prefix(maxResults)
                .map { $0 }
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else {
                if generation == searchGeneration { isLoading = false }
                return
            }
            // Silent: this is a supplementary strip, not the primary search.
            results = []
        }
        if generation == searchGeneration { isLoading = false }
    }

    /// Bus consumer: flip ribbons in place after a create elsewhere.
    func applyRequestUpdate(_ record: MediaRequest) {
        results.applyRequestUpdate(record)
    }

    func applyTitleState(_ update: RequestTitleStateUpdate) {
        results.applyTitleState(update)
    }
}
