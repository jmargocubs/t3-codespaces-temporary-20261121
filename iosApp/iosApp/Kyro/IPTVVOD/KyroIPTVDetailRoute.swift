#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation

/// Saved progress for a provider title, or for one episode of a provider series.
struct XtreamVODWatchState: Codable, Equatable {
    var position: Double = 0
    var duration: Double = 0
    var updatedAt = Date()
    var favorite = false
    var completed = false
}

/// What an IPTV poster opens: a provider title as the root of the app's detail card, the card a
/// Silo poster opens through `AppRouter.presentItemDetail`. The poster is Silo's `MediaCard` and
/// its tap calls `AppRouter.presentIPTVDetail`, so both sources share one card, one tap target and
/// one dismissal path.
///
/// Builds 100 to 102 wrapped `MediaCard` in a view-destination `NavigationLink`. `MediaCard` is
/// itself a `Button`, so the inner button took every tap (Build 102: the press highlight showed
/// and its empty action ran) or, with hit testing turned off on the label (Builds 100 and 101),
/// nothing took the tap at all. The link never fired in either build.
struct KyroIPTVDetailRequest: Hashable {
    enum Page: Hashable {
        /// Hero with Play / Resume / Start Over.
        case movie
        /// Hero with Play or Resume for the next episode, seasons and the episode list.
        case series
    }

    let item: XtreamVODItem
    let providerName: String

    var page: Page { item.kind == .movie ? .movie : .series }

    /// The card's page identity. The prefix keeps it from ever being read as a Silo content ID;
    /// the item ID carries the provider, kind and remote ID, so two providers never share a page.
    var pageIdentity: String { "iptv:\(item.id)" }
}

/// How a provider detail page hands a title to the shared player: where playback starts, and how
/// the player names the title and its source. `KyroIPTVVODDetailView` builds its
/// `ExternalPlaybackRequest` from these.
enum KyroIPTVPlaybackPlan {
    /// Less progress than this starts the title over rather than offering Resume.
    static let resumeThreshold: Double = 15

    static func isResumable(_ state: XtreamVODWatchState) -> Bool {
        !state.completed && state.position > resumeThreshold
    }

    /// The saved position when the title can resume, unless the viewer chose Start Over.
    static func startPosition(for state: XtreamVODWatchState, fromStart: Bool) -> Double {
        !fromStart && isResumable(state) ? state.position : 0
    }

    /// The fraction watched, for the Play button's progress bar. Nil when nothing resumes.
    static func progress(for state: XtreamVODWatchState) -> Double? {
        guard isResumable(state), state.duration > 0 else { return nil }
        return min(1, state.position / state.duration)
    }

    static func title(for item: XtreamVODItem, episode: XtreamVODEpisode?) -> String {
        episode.map { "\(item.title) · S\($0.season) E\($0.number)" } ?? item.title
    }

    static func sourceLabel(providerName: String) -> String { "IPTV · \(providerName)" }

    /// The player request for a title or episode. `playURL` is the provider's stream URL, or the
    /// relay URL standing in for it (`XtreamVODStreamRoute.relayed`).
    static func request(
        playURL: URL, item: XtreamVODItem, episode: XtreamVODEpisode?, providerName: String,
        state: XtreamVODWatchState, fromStart: Bool,
        probe: (@MainActor () async -> ExternalStreamProbeReport?)? = nil,
        onFinish: (@MainActor (_ position: Double, _ duration: Double, _ ended: Bool) -> Void)? = nil
    ) -> ExternalPlaybackRequest {
        ExternalPlaybackRequest(
            url: playURL,
            title: title(for: item, episode: episode),
            sourceLabel: sourceLabel(providerName: providerName),
            startPosition: startPosition(for: state, fromStart: fromStart),
            probe: probe,
            onFinish: onFinish
        )
    }

    /// The episode a series page's Play button offers: the most recently watched unfinished
    /// episode, else the one after the last finished episode. Nil means the first episode.
    static func resumeEpisode(
        in episodes: [XtreamVODEpisode],
        state: (XtreamVODEpisode) -> XtreamVODWatchState
    ) -> XtreamVODEpisode? {
        let states = episodes.map { ($0, state($0)) }
        if let resume = states.filter({ isResumable($0.1) }).max(by: { $0.1.updatedAt < $1.1.updatedAt }) {
            return resume.0
        }
        if let lastDone = states.lastIndex(where: { $0.1.completed }), lastDone + 1 < states.count {
            return states[lastDone + 1].0
        }
        return nil
    }
}
#endif
