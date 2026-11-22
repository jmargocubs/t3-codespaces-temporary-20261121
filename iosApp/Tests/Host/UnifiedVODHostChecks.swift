#if KYRO_VOD_HOST_TESTS
import Foundation

struct BrowseItem {
    let contentId: String
    let type: String
    let title: String
    let year: Int?
    let posterUrl: String?
}
enum XtreamVODKind { case movie, series }
struct XtreamVODItem {
    let providerID: UUID
    let kind: XtreamVODKind
    let remoteID: Int
    let title: String
    let poster: String?
    var id: String { "\(providerID):\(kind):\(remoteID)" }
}
enum XtreamVODTitle {
    static func year(in title: String) -> Int? {
        guard let suffix = title.split(separator: "(").last?.replacingOccurrences(of: ")", with: ""),
              let year = Int(suffix) else { return nil }
        return year
    }
}
enum RequestMediaType { case movie, series }
struct RequestMediaResult {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
}

@main
enum UnifiedVODHostChecks {
    static func main() {
        let first = UUID(), second = UUID()
        let silo = UnifiedVODEntry(silo: .init(contentId: "1", type: "movie", title: "Arrival", year: 2016, posterUrl: nil))
        let iptv = UnifiedVODEntry(iptv: .init(providerID: first, kind: .movie, remoteID: 7,
                                                title: "Arrival (2016)", poster: nil))
        let other = UnifiedVODEntry(iptv: .init(providerID: second, kind: .movie, remoteID: 8,
                                                 title: "Arrival (2016)", poster: nil))
        let duplicateSilo = UnifiedVODEntry(silo: .init(contentId: "2", type: "movie", title: "Arrival", year: 2016, posterUrl: nil))
        assert(UnifiedVODCatalog.aggregate([silo, iptv, other]).first?.entries.count == 3)
        let merged = UnifiedVODCatalog.aggregate([iptv, silo, other])[0]
        assert(merged.primaryEntry?.id == silo.id)
        assert(Set(merged.iptvItems.map(\.providerID)) == [first, second])
        assert(UnifiedVODCatalog.aggregate([iptv])[0].primaryEntry?.id == iptv.id)
        assert(UnifiedVODCatalog.aggregate([silo])[0].primaryEntry?.id == silo.id)
        let removed = UnifiedVODCatalog.aggregate([silo, iptv, other].filter { $0.origin != .iptv(first) })
        assert(removed.first?.entries.map(\.id) == [silo.id, other.id])
        assert(UnifiedVODCatalog.aggregate([silo, duplicateSilo, iptv]).count == 3)
        assert(UnifiedVODCatalog.aggregate([silo, UnifiedVODEntry(id: "series", origin: .iptv(first),
            kind: .series, title: "Arrival", year: 2016)]).count == 2)
        let series = UnifiedVODCatalog.aggregate([
            UnifiedVODEntry(id: "series-a", origin: .iptv(first), kind: .series, title: "Show", year: 2020),
            UnifiedVODEntry(id: "series-b", origin: .iptv(second), kind: .series, title: "Show", year: 2020)
        ])[0]
        assert(series.sources(for: .init(season: 2, episode: 1), resolvedEpisodes: [
            "series-a": [.init(season: 2, episode: 1)], "series-b": [.init(season: 1, episode: 1)]
        ]).map(\.id) == ["series-a"])
        assert(UnifiedVODCatalog.matchesRequest(.init(mediaType: .movie, tmdbId: 1,
            title: "Arrival", year: 2016), entry: iptv))
        assert(!UnifiedVODCatalog.matchesRequest(.init(mediaType: .movie, tmdbId: 2,
            title: "Missing", year: 2016), entry: iptv))
        let requests = [RequestMediaResult(mediaType: .movie, tmdbId: 1, title: "Arrival", year: 2016),
                        RequestMediaResult(mediaType: .movie, tmdbId: 2, title: "Missing", year: 2016)]
        assert(UnifiedVODCatalog.requestableResults(requests, local: [iptv], siloReady: true, vodReady: false).isEmpty)
        assert(UnifiedVODCatalog.requestableResults(requests, local: [iptv], siloReady: false, vodReady: true).isEmpty)
        assert(UnifiedVODCatalog.requestableResults(requests, local: [iptv], siloReady: true, vodReady: true)
            .map(\.title) == ["Missing"])
        assert(VODPlaybackPolicy.order(sources: [iptv, silo]).map(\.id) == [silo.id, iptv.id])
        assert(VODPlaybackPolicy.order(sources: [iptv, silo], failedIDs: [silo.id]).map(\.id) == [iptv.id])
        assert(VODPlaybackPolicy.order(sources: [iptv, silo], usableIDs: [iptv.id]).map(\.id) == [iptv.id])
        assert(VODPlaybackPolicy.order(sources: [iptv, silo], playbackStarted: true).isEmpty)
        var tracker = VODSearchRequestTracker()
        let typing = tracker.begin("Fraidy")
        assert(tracker.accepts(typing, query: " Fraidy ")) // submit/keyboard dismissal preserve identity
        let submitted = tracker.begin("Fraidy series")
        assert(!tracker.accepts(typing, query: "Fraidy")) // stale movie response cannot overwrite
        assert(tracker.accepts(submitted, query: "Fraidy series"))
        tracker.cancel()
        assert(!tracker.accepts(submitted, query: "Fraidy series"))
        print("Unified VOD host checks passed")
    }
}
#endif
