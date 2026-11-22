import Foundation

/// Per-provider guide generations: a number that changes every time a provider's guide index is
/// installed, replaced or removed. `LiveTVService.guideRevision` does not change for short-guide
/// overlays, so anything that caches work derived from a whole guide (program search) keys it on
/// this instead.
///
/// Every value comes from one counter, so a provider that is removed and added again, or two
/// providers, never share a generation. Zero means no guide index has been published yet.
struct EPGGuideGenerations: Equatable, Sendable {
    private var latest = 0
    private var byProvider: [UUID: Int] = [:]

    func generation(for providerID: UUID) -> Int { byProvider[providerID] ?? 0 }

    /// Records a guide index change for `providerID` and returns its new generation.
    @discardableResult
    mutating func advance(_ providerID: UUID) -> Int {
        latest &+= 1
        byProvider[providerID] = latest
        return latest
    }
}
