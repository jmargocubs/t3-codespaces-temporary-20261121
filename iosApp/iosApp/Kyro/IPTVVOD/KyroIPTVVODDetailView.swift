#if os(iOS)
import SwiftUI

/// A provider title's detail page, built from the same phone detail components as Silo's movie
/// and series pages (and offline downloads): `PhoneDetailPageSurface`, `PhoneDetailHero`,
/// `PhonePrimaryPillButton`, `PhoneLabeledActionRow` and `PhoneSectionHeader`.
///
/// It is the root of the app's detail card (`AppRouter.presentIPTVDetail`), the card Silo titles
/// open in, and draws the same floating Close button and scroll glass as Silo's detail page.
///
/// Playback opens Silo's `PlayerView` with an `ExternalPlaybackRequest`, so IPTV titles get the
/// same player chrome, PiP and transport as Silo titles.
struct KyroIPTVVODDetailView: View {
    let item: XtreamVODItem
    let providerName: String
    @Environment(AppRouter.self) private var router
    /// Closes the detail card. Nil draws no Close button.
    var onClose: (() -> Void)? = nil
    /// Pushed over another title's detail (a matched title's alternate source): the leading
    /// control reads as Back and `onClose` pops this page instead of closing the card.
    var isPushedAlternate = false

    private let service = XtreamVODService.shared
    @State private var detail: XtreamVODDetail?
    @State private var enriched: RequestMediaDetail?
    @State private var isFavorite = false
    @State private var detailFailed: String?
    @State private var playbackError: String?
    @State private var playback: ExternalPlaybackRequest?
    @State private var selectedSeason: Int?
    @State private var scrollState = PhoneDetailScrollState()
    /// Set while the stream's route is checked before the player opens, so a second tap waits.
    @State private var isPreparingPlayback = false

    var body: some View {
        PhoneDetailPageSurface(
            backdropURL: presentation.backdropURL ?? item.poster,
            backdropThumbhash: nil,
            enablesArtworkGlass: true
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    hero
                    if item.kind == .series {
                        episodesSection
                            .padding(.horizontal, SiloTheme.safePadding)
                    }
                    if !presentation.castNames.isEmpty || detail?.writers != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            PhoneSectionHeader(title: "Cast & Crew")
                            if !presentation.castNames.isEmpty {
                                Text(presentation.castNames.joined(separator: " · "))
                                    .font(.siloBody)
                                    .foregroundColor(.siloSecondaryText)
                            }
                            if let writers = detail?.writers {
                                Text("Written by \(writers)")
                                    .font(.siloCaption)
                                    .foregroundColor(.siloSecondaryText)
                            }
                        }
                        .padding(.horizontal, SiloTheme.padding)
                    }
                    if let trailerURL = detail?.trailerURL {
                        Link(destination: trailerURL) {
                            Label("Watch Trailer", systemImage: "play.rectangle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.siloOnSurface)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(.horizontal, SiloTheme.padding)
                    }
                    if let enriched, let recommendations = enriched.recommendations, !recommendations.isEmpty {
                        VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
                            RequestsSectionHeader(title: "More like this")
                            RequestCardRail(items: Array(recommendations.prefix(12))) { result in
                                RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                            }
                        }
                        .padding(.horizontal, SiloTheme.padding)
                    }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
            .phoneDetailScrollTracking(scrollState)
        }
        // Like Silo's detail card: no navigation bar, so the artwork reaches the card's top edge,
        // and floating controls instead.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            PhoneDetailTopChrome(
                title: item.title,
                isScrollGlassEnabled: true,
                scrollState: scrollState,
                leadingSystemName: onClose == nil ? nil : (isPushedAlternate ? "chevron.left" : "xmark"),
                leadingAccessibilityLabel: onClose == nil ? nil : (isPushedAlternate ? "Back" : "Close details"),
                onLeadingTap: { onClose?() },
                trailingSystemName: nil,
                onTrailingTap: nil
            )
        }
        .task(id: item.id) {
            isFavorite = service.watchState(for: item).favorite
            do {
                let loaded = try await service.detail(for: item)
                detail = loaded
                if selectedSeason == nil { selectedSeason = resumeEpisode(in: loaded)?.season ?? loaded.seasons.first }
                enriched = await KyroIPTVMetadataEnrichment.shared.detail(for: item, providerDetail: loaded)
            } catch {
                detailFailed = (error as? LocalizedError)?.errorDescription ?? "Details are unavailable."
                enriched = await KyroIPTVMetadataEnrichment.shared.detail(for: item, providerDetail: nil)
            }
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(
                contentId: "iptv-vod-\(request.id.uuidString)",
                externalPlayback: request,
                onDismissRequested: { playback = nil }
            )
            .id(request.id)
            .interactiveDismissDisabled()
        }
    }

    // MARK: Hero

    private var hero: some View {
        PhoneDetailHero(
            title: item.title,
            logoUrl: nil,
            posterUrl: presentation.posterURL,
            posterThumbhash: nil,
            backdropUrl: presentation.backdropURL,
            backdropThumbhash: nil,
            eyebrow: nil,
            sourceTokens: presentation.genres,
            ratingChip: presentation.contentRating ?? presentation.providerRatingChip,
            overview: presentation.synopsis,
            factsLine: presentation.facts,
            ratings: presentation.ratings,
            creditText: presentation.creditText,
            overlayData: nil,
            enablesArtworkParallax: true,
            artworkStyle: presentation.backdropURL == nil
                ? .cover(aspectRatio: 2.0 / 3.0, placeholderSymbol: item.kind == .movie ? "film" : "tv")
                : .backdrop,
            actions: { actions },
            belowOverview: { EmptyView() }
        )
    }

    private var presentation: KyroIPTVDetailPresentation {
        KyroIPTVDetailPresentation(item: item, provider: detail, metadata: enriched)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            if item.kind == .movie {
                let state = service.watchState(for: item)
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: isPreparingPlayback ? "Starting…" : (KyroIPTVPlaybackPlan.isResumable(state) ? "Resume" : "Play"),
                    action: { play(episode: nil, fromStart: false) },
                    fullWidth: true,
                    progress: KyroIPTVPlaybackPlan.progress(for: state)
                )
                if KyroIPTVPlaybackPlan.isResumable(state) {
                    PhoneLabeledActionRow {
                        PhoneLabeledAction(icon: "gobackward", label: "Start Over", isToggle: false) {
                            play(episode: nil, fromStart: true)
                        }
                    }
                }
            } else if let detail, let episode = resumeEpisode(in: detail) ?? detail.episodes.first {
                let state = service.watchState(for: item, episode: episode)
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: isPreparingPlayback ? "Starting…"
                        : "\(KyroIPTVPlaybackPlan.isResumable(state) ? "Resume" : "Play") S\(episode.season) E\(episode.number)",
                    action: { play(episode: episode, fromStart: false) },
                    fullWidth: true,
                    progress: KyroIPTVPlaybackPlan.progress(for: state)
                )
            } else if detail == nil, detailFailed == nil {
                ProgressView().tint(.siloOnSurface).frame(minHeight: 52)
            }
            if let message = playbackError ?? detailFailed {
                Text(message)
                    .font(.siloCaption)
                    .foregroundColor(.siloErrorInk)
                    .multilineTextAlignment(.center)
            }
            PhoneLabeledActionRow {
                PhoneLabeledAction(icon: "heart", iconActive: "heart.fill", isActive: isFavorite,
                                   label: "Favorite", accessibilityLabelOverride: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    isFavorite.toggle()
                    service.setFavorite(isFavorite, for: item)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesSection: some View {
        if let detail, !detail.episodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                PhoneSectionHeader(title: "Episodes", trailingText: seasonCaption(detail))
                if detail.seasons.count > 1 {
                    seasonChips(detail.seasons)
                }
                VStack(spacing: 0) {
                    let episodes = detail.episodes.filter { $0.season == (selectedSeason ?? detail.seasons.first) }
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 {
                            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        }
                        episodeRow(episode)
                    }
                }
            }
        }
    }

    private func seasonCaption(_ detail: XtreamVODDetail) -> String {
        detail.seasons.count == 1 ? "1 season" : "\(detail.seasons.count) seasons"
    }

    /// Silo's season chip look: filled white capsule when selected, outlined otherwise.
    private func seasonChips(_ seasons: [Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { season in
                    let selected = season == selectedSeason
                    Button {
                        selectedSeason = season
                    } label: {
                        Text(season == 0 ? "Specials" : "Season \(season)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(selected ? .black : .siloOnSurface)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background {
                                if selected {
                                    Capsule().fill(Color.white)
                                } else {
                                    Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func episodeRow(_ episode: XtreamVODEpisode) -> some View {
        let state = service.watchState(for: item, episode: episode)
        return Button {
            play(episode: episode, fromStart: false)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("\(episode.number)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(.siloOnSurface.opacity(0.6))
                    .frame(minWidth: 24, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundColor(.siloOnSurface.opacity(0.6))
                            .lineLimit(2)
                    }
                    if let progress = KyroIPTVPlaybackPlan.progress(for: state) {
                        ProgressView(value: progress)
                            .tint(.white)
                            .frame(maxWidth: 120)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: state.completed ? "checkmark.circle.fill" : "play.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.siloOnSurface.opacity(state.completed ? 0.5 : 0.85))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Episode \(episode.number), \(episode.title)")
    }

    // MARK: Playback

    /// The most recently watched unfinished episode, else the first unwatched one.
    private func resumeEpisode(in detail: XtreamVODDetail) -> XtreamVODEpisode? {
        KyroIPTVPlaybackPlan.resumeEpisode(in: detail.episodes) { service.watchState(for: item, episode: $0) }
    }

    private func play(episode: XtreamVODEpisode?, fromStart: Bool) {
        guard !isPreparingPlayback else { return }
        playbackError = nil
        let streamURL: URL
        do {
            streamURL = try service.playbackURL(for: item, episode: episode)
        } catch {
            playbackError = (error as? LocalizedError)?.errorDescription ?? "This title cannot be played."
            return
        }
        let state = service.watchState(for: item, episode: episode)
        // Xtream accounts commonly allow one stream at a time. Live TV (including an inline
        // Sports player or its Picture in Picture window) would hold that connection and the
        // provider would refuse this one, so release it first.
        let liveTV = LiveTVService.shared
        if liveTV.playerSession.state != .stopped { liveTV.endPlayback() }
        isPreparingPlayback = true
        let service = service
        let item = item
        let providerName = providerName
        Task {
            defer { isPreparingPlayback = false }
            // Build 104: a provider that redirects to plain HTTP plays through the loopback relay;
            // everything else keeps the provider URL, as before.
            let started = KyroPerformanceClock.now()
            let resolved = await XtreamVODStreamRoute.resolve(streamURL)
            KyroPerformanceDiagnostics.record(.iptvStreamRoute, milliseconds: (KyroPerformanceClock.now() - started) * 1000)
            let playURL: URL
            switch resolved.route {
            case .direct:
                playURL = streamURL
            case .relayed:
                do {
                    playURL = try await XtreamVODCleartextRelay.shared.url(for: streamURL)
                } catch {
                    playbackError = "This title cannot be played right now."
                    return
                }
            }
            XtreamVODDiagnostics.event(resolved.route == .relayed ? "play_relayed" : "play_direct",
                                       kind: item.kind, count: resolved.hops)
            playback = KyroIPTVPlaybackPlan.request(
                playURL: playURL, item: item, episode: episode, providerName: providerName,
                state: state, fromStart: fromStart,
                probe: { await XtreamVODStreamProbe.probe(playURL) },
                onFinish: { position, duration, ended in
                    service.saveProgress(position: ended ? max(position, duration) : position,
                                         duration: duration, item: item, episode: episode)
                    if resolved.route == .relayed { XtreamVODCleartextRelay.shared.release(playURL) }
                }
            )
        }
    }
}

private extension XtreamVODDetail {
    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
}

/// The IPTV page projects provider and optional TMDB facts into the same hero contract used by
/// Silo and Requests. Playback identity is deliberately absent from this presentation model.
struct KyroIPTVDetailPresentation {
    let item: XtreamVODItem
    let provider: XtreamVODDetail?
    let metadata: RequestMediaDetail?

    var posterURL: String? { RequestImageURL.build(metadata?.posterPath, size: .poster) ?? item.poster }
    var backdropURL: String? { RequestImageURL.build(metadata?.backdropPath, size: .backdrop) }
    var synopsis: String? { provider?.summary ?? item.summary ?? metadata?.overview }
    var contentRating: String? { metadata?.contentRating }
    var providerRatingChip: String? {
        guard metadata == nil, let raw = provider?.rating ?? item.rating,
              let score = Double(raw), score > 0 else { return nil }
        return String(format: "★ %.1f", score)
    }
    var genres: [String] {
        if let genres = metadata?.genres, !genres.isEmpty { return Array(genres.prefix(3)) }
        guard let raw = provider?.genre ?? item.genre else { return [] }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return Array(names.filter { !$0.isEmpty }.prefix(3))
    }
    var facts: [PhoneHeroFactToken] {
        var parts: [String] = []
        if let year = provider?.releaseYear ?? XtreamVODTitle.year(in: item.title) ?? metadata?.year {
            parts.append(String(year))
        }
        if item.kind == .movie {
            let minutes = provider?.duration.map { Int(($0 / 60).rounded()) } ?? metadata?.runtime
            if let runtime = MediaTextFormatting.runtime(minutes: minutes) { parts.append(runtime) }
        } else if let episodes = provider?.episodes, !episodes.isEmpty {
            parts.append("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
        } else if let count = metadata?.numberOfEpisodes, count > 0 {
            parts.append("\(count) episodes")
        }
        return parts.map(PhoneHeroFactToken.text)
    }
    var ratings: [DisplayRating] {
        return DisplayRating.tmdb(metadata?.voteAverage).map { [$0] } ?? []
    }
    var creditText: String? {
        if let director = metadata?.director, !director.isEmpty { return "Directed by \(director)" }
        if let director = provider?.director, !director.isEmpty { return "Directed by \(director)" }
        if let creators = metadata?.creators, !creators.isEmpty {
            return "Created by \(creators.prefix(2).joined(separator: ", "))"
        }
        return nil
    }
    var castNames: [String] {
        guard let raw = provider?.cast else { return [] }
        return Array(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(12))
    }
}

/// Conservative, on-demand matching. An external ID wins only within the same media type;
/// title lookup requires an exact normalized title and year and exactly one candidate.
enum KyroIPTVMetadataMatch {
    static func searchTitle(_ title: String, year: Int?) -> String {
        guard let year else { return title }
        for suffix in [" (\(year))", " [\(year)]", " - \(year)"] where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }

    static func uniqueID(item: XtreamVODItem, providerDetail: XtreamVODDetail?,
                         candidates: [RequestMediaResult]) -> Int? {
        let type: RequestMediaType = item.kind == .movie ? .movie : .series
        if let id = providerDetail?.tmdbID, id > 0 { return id }
        guard let year = providerDetail?.releaseYear ?? XtreamVODTitle.year(in: item.title),
              !UnifiedCatalogKeys.normalizedTitle(item.title, year: year).isEmpty else { return nil }
        let title = UnifiedCatalogKeys.normalizedTitle(item.title, year: year)
        let matches = candidates.filter {
            $0.mediaType == type && $0.year == year &&
            UnifiedCatalogKeys.normalizedTitle($0.title, year: $0.year) == title
        }
        return matches.count == 1 ? matches[0].tmdbId : nil
    }
}

/// Uses the existing profile-scoped Silo/TMDB request endpoints; no app API key or catalog-wide
/// scan. Results are bounded in memory, duplicate opens share one task, and failures stay local.
@MainActor
final class KyroIPTVMetadataEnrichment {
    static let shared = KyroIPTVMetadataEnrichment()
    private let search: @MainActor (String, RequestMediaType) async throws -> RequestMediaPage
    private let load: @MainActor (RequestMediaType, Int) async throws -> RequestMediaDetail
    private var cached: [String: RequestMediaDetail] = [:]
    private var order: [String] = []
    private var pending: [String: Task<RequestMediaDetail?, Never>] = [:]
    private var nextRequestAt = Date.distantPast
    private var generation = 0

    init(search: @MainActor @escaping (String, RequestMediaType) async throws -> RequestMediaPage = {
        try await SiloAPI.shared.requestsSearch(query: $0, mediaType: $1, page: 1)
    }, load: @MainActor @escaping (RequestMediaType, Int) async throws -> RequestMediaDetail = {
        try await SiloAPI.shared.requestsDetail(mediaType: $0, tmdbId: $1)
    }) {
        self.search = search
        self.load = load
    }

    func clear() {
        generation &+= 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        cached.removeAll()
        order.removeAll()
    }

    func detail(for item: XtreamVODItem, providerDetail: XtreamVODDetail?) async -> RequestMediaDetail? {
        let key = "\(AuthService.shared.profileId ?? "local"):\(item.id)"
        if let detail = cached[key] { return detail }
        if let task = pending[key] { return await task.value }
        let session = generation
        let task = Task<RequestMediaDetail?, Never> { [weak self] in
            guard let self else { return nil }
            let type: RequestMediaType = item.kind == .movie ? .movie : .series
            let id: Int
            if let externalID = providerDetail?.tmdbID, externalID > 0 {
                id = externalID
            } else {
                guard (providerDetail?.releaseYear ?? XtreamVODTitle.year(in: item.title)) != nil else { return nil }
                await pace()
                guard !Task.isCancelled,
                      let page = try? await search(
                        KyroIPTVMetadataMatch.searchTitle(item.title,
                            year: providerDetail?.releaseYear ?? XtreamVODTitle.year(in: item.title)), type),
                      let match = KyroIPTVMetadataMatch.uniqueID(item: item, providerDetail: providerDetail,
                                                                  candidates: page.results) else { return nil }
                id = match
            }
            await pace()
            guard !Task.isCancelled,
                  let result = try? await load(type, id),
                  result.mediaType == type, session == generation else { return nil }
            cached[key] = result
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > 80 { cached.removeValue(forKey: order.removeFirst()) }
            return result
        }
        pending[key] = task
        let result = await task.value
        pending.removeValue(forKey: key)
        return result
    }

    private func pace() async {
        let delay = max(0, nextRequestAt.timeIntervalSinceNow)
        nextRequestAt = Date().addingTimeInterval(delay + 0.5)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }
}
#endif
