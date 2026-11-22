import CoreGraphics
import Foundation

/// The watch screen's channel list: per-row values memoized for the current guide and minute, and
/// the arithmetic that brings the playing channel into view without walking the catalog.
///
/// Build 60 measurements (SwiftUI on macOS 26 with 40,000 rows; counts, not device timing):
/// - `ScrollViewReader.scrollTo(id)` on a `LazyVStack` evaluated the `ForEach` row closure for
///   every row before the target, twice: 40,020 closures for row 20,000, 78,001 for row 39,000,
///   and 80,000 when the ID was not in the list at all (the playing channel outside the chosen
///   category). The Build 59 list did this on every switch to List and every outside retune, and
///   each closure ran two guide lookups that fold the channel name (12.8 µs per fold).
/// - `ScrollPosition.scrollTo(id:)` evaluated 30,086 closures for row 30,000.
/// - Scrolling to a point evaluated 77.
/// So the list scrolls to an estimated point, then corrects once from the playing row's own frame.

/// Memoized list rows. Not observed: it only caches values derived from observed service state.
@MainActor
final class LiveTVGuideListEntryCache {
    /// About seven screenfuls of 64–90 point rows, like the grid's cell cache.
    static let capacity = 96

    private struct Key: Equatable {
        let revision: Int
        let isGuideStale: Bool
        let minute: Date
    }

    private struct Entry {
        let entry: LiveTVEmbeddedGuideListEntry
        let channelRevision: Int
    }

    private var key: Key?
    private var storage: [String: Entry] = [:]
    private var recency: [String] = []
    private(set) var hitCount = 0
    private(set) var missCount = 0

    var entryCount: Int { storage.count }

    /// `cacheable`: false while the channel's listings could still arrive. Build 60 stored the
    /// first value it built, so a row built before its listings loaded, or whose load request a
    /// full queue had dropped, kept "No guide information" until the next minute (Build 61).
    func entry(for channel: LiveTVChannel, revision: Int, isGuideStale: Bool, now: Date, channelRevision: Int,
               cacheable: Bool = true,
               make: () -> LiveTVEmbeddedGuideListEntry) -> LiveTVEmbeddedGuideListEntry {
        let key = Key(revision: revision, isGuideStale: isGuideStale, minute: Self.minute(now))
        if key != self.key {
            self.key = key
            storage.removeAll(keepingCapacity: true)
            recency.removeAll(keepingCapacity: true)
        }
        if cacheable, let cached = storage[channel.id], cached.channelRevision == channelRevision {
            hitCount += 1
            touch(channel.id)
            return cached.entry
        }
        missCount += 1
        let built = make()
        guard cacheable else {
            if storage.removeValue(forKey: channel.id) != nil, let index = recency.firstIndex(of: channel.id) {
                recency.remove(at: index)
            }
            return built
        }
        storage[channel.id] = Entry(entry: built, channelRevision: channelRevision)
        touch(channel.id)
        if storage.count > Self.capacity, let evicted = recency.popLast() {
            storage.removeValue(forKey: evicted)
        }
        return built
    }

    private func touch(_ id: String) {
        if let index = recency.firstIndex(of: id) { recency.remove(at: index) }
        recency.insert(id, at: 0)
    }

    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

/// The list's live geometry, written while scrolling without invalidating any view.
final class LiveTVGuideListScrollTracker {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

/// A pending reveal of the playing row. Cleared once the row reports its frame and is centred.
struct LiveTVGuideListRevealRequest: Equatable {
    let channelID: String
    var attempt: Int
}

enum LiveTVGuideListReveal {
    /// Rows in Build 59 measured 64–94 points; used only before the list has a content height.
    static let fallbackRowHeight: CGFloat = 78
    static let maximumAttempts = 3

    /// Where to scroll so row `index` sits near the middle. `contentHeight` is the lazy stack's own
    /// estimate for every row, so its average row height matches where the stack will place the row.
    static func estimatedOffset(index: Int, rowCount: Int, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard rowCount > 0, index >= 0 else { return 0 }
        let total = contentHeight > 0 ? contentHeight : fallbackRowHeight * CGFloat(rowCount)
        let rowHeight = total / CGFloat(rowCount)
        let target = (CGFloat(min(index, rowCount - 1)) + 0.5) * rowHeight - viewportHeight / 2
        return clamp(target, total: total, viewportHeight: viewportHeight)
    }

    /// The offset that centres a row whose middle is at `rowContentMidY` in the list's content
    /// coordinates. Content coordinates do not move with scrolling, so the result does not depend
    /// on which geometry callback ran first. Nil when the row is already within a few points.
    static func correctedOffset(rowContentMidY: CGFloat, currentOffset: CGFloat, contentHeight: CGFloat,
                                viewportHeight: CGFloat) -> CGFloat? {
        let target = clamp(rowContentMidY - viewportHeight / 2, total: contentHeight, viewportHeight: viewportHeight)
        guard abs(target - currentOffset) > 4 else { return nil }
        return target
    }

    private static func clamp(_ value: CGFloat, total: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(0, value), max(0, total - viewportHeight))
    }
}
