import Foundation

/// The portrait watch screen: a channel chosen in the guide plays in a 16:9 player pinned above
/// Details and Guide tabs. It is a layout over the one Live TV session, not a second player: the
/// presentation still says `.presented(channel, .guide)`, and every switch, expansion and Picture
/// in Picture hand-off goes through the same `LiveTVPresentation` and `LiveTVPlayerSession`.
enum LiveTVWatchScreen {
    /// Only iPhone opens the watch screen. iPad and other hosts keep the full-screen player, where
    /// a portrait 16:9 frame would waste the screen.
    static func isEnabled(isPhone: Bool) -> Bool { isPhone }

    /// Whether the watch screen leaving the screen ends the stream. The full-screen player it
    /// expanded into covers it, and SwiftUI can report a covered view as disappearing; the
    /// stream plays on there. Picture in Picture keeps it too, as for the full-screen player.
    static func shouldStopWhenWatchScreenDisappears(phase: LiveTVPresentation.Phase, isExpanded: Bool) -> Bool {
        guard !isExpanded else { return false }
        return LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(phase)
    }

    /// The same rule for one watch screen instance, which may only end the stream while it is
    /// still the current presentation. A screen that never appeared owns nothing.
    @MainActor
    static func shouldStopWhenWatchScreenDisappears(presentation: LiveTVPresentation, presentedAt epoch: Int?,
                                                    isPictureInPictureEngaged: Bool = false) -> Bool {
        guard let epoch, !presentation.isWatchExpanded else { return false }
        return presentation.shouldStopWhenPlayerDisappears(presentedAt: epoch,
                                                           isPictureInPictureEngaged: isPictureInPictureEngaged)
    }
}

/// The watch screen's tabs.
enum LiveTVWatchTab: String, CaseIterable, Identifiable, Hashable {
    case details
    case guide

    var id: Self { self }

    var title: String {
        switch self {
        case .details: "Details"
        case .guide: "Guide"
        }
    }
}

/// What the watch screen's 16:9 frame hosts. One surface shows the stream at a time.
enum LiveTVWatchSurfaceMode: Equatable {
    /// The engine surface is mounted in the frame.
    case video(LiveTVChannel)
    /// The full-screen player above holds the stream; the frame keeps its place without a surface,
    /// so it cannot rebind the engine's layer away from the full-screen player.
    case expanded(LiveTVChannel)
    /// Picture in Picture holds the stream. The frame shows a placeholder and does not mount a
    /// surface, so it cannot rebind the engine's layer away from the system window.
    case pictureInPicture(LiveTVChannel)
    /// The cover is on its way out (a stop, a removed provider, or an inline handoff).
    case none

    static func make(phase: LiveTVPresentation.Phase, isExpanded: Bool,
                     isExpandedSurfaceMounted: Bool = true) -> Self {
        switch phase {
        case .presented(let channel, _), .restoring(let channel, _):
            // Keep the portrait surface until the incoming full-screen surface confirms that it
            // mounted. Aether then owns the incoming view before SwiftUI dismantles the outgoing
            // one, whose identity-guarded unbind cannot detach its successor.
            isExpanded && isExpandedSurfaceMounted ? .expanded(channel) : .video(channel)
        case .pictureInPicture(let channel):
            .pictureInPicture(channel)
        case .idle, .inline:
            .none
        }
    }

    var channel: LiveTVChannel? {
        switch self {
        case .video(let channel), .expanded(let channel), .pictureInPicture(let channel): channel
        case .none: nil
        }
    }

    var hostsSurface: Bool {
        if case .video = self { return true }
        return false
    }
}

/// The watch screen's Guide tab can show a channel list or the timeline. The pushed Live TV
/// Guide does not use this; it stays the timeline. Missing or unknown stored values are List,
/// so the first visit is the list.
enum LiveTVEmbeddedGuideStyle: String, CaseIterable, Identifiable, Sendable {
    case list
    case grid

    var id: Self { self }

    var title: String {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        }
    }

    /// UserDefaults key. The watch screen reads and writes it; the pushed guide never does.
    static let defaultsKey = "liveTV.watchGuide.style.v1"

    static func resolve(stored: String?) -> Self {
        guard let stored, let style = Self(rawValue: stored) else { return .list }
        return style
    }
}

/// Filters belong to the guide, not to whichever view is showing. Choosing the other view
/// copies them and never asks the player to retune.
struct LiveTVEmbeddedGuideBrowsing: Equatable, Sendable {
    var style: LiveTVEmbeddedGuideStyle
    var category: String?
    var favoritesOnly: Bool
    var searchQuery: String

    func selecting(_ style: LiveTVEmbeddedGuideStyle) -> Self {
        var copy = self
        copy.style = style
        return copy
    }

    /// A view change is layout only. The playing session stays on its channel.
    static func retunes(from: LiveTVEmbeddedGuideStyle, to: LiveTVEmbeddedGuideStyle) -> Bool { false }
}

/// One row of the watch screen's channel list, from the same guide data as the timeline.
struct LiveTVEmbeddedGuideListEntry: Equatable, Sendable {
    let currentTitle: String?
    /// Elapsed share of the current programme, 0...1. Nil when nothing is airing.
    let progress: Double?
    let upcomingTitle: String?
    let upcomingStart: Date?

    /// Far enough ahead to include the programme after the current one.
    static let lookahead: TimeInterval = 6 * 60 * 60

    static func make(channel: LiveTVChannel, programs: [EPGProgram], fallback: LiveTVProgramPair, now: Date) -> Self {
        let details = LiveTVWatchDetails.make(channel: channel, programs: programs, fallback: fallback, now: now)
        let next = details.upcoming.first
        return Self(currentTitle: details.current?.title, progress: details.progress,
                    upcomingTitle: next?.title, upcomingStart: next?.start)
    }
}

/// What a guide tap means inside the watch screen.
enum LiveTVWatchSwitch: Equatable {
    /// The channel is already playing: keep the stream, do not retune.
    case alreadyPlaying
    /// Retune the one session to the channel in place.
    case retune

    static func resolve(selectedChannelID: String, activeChannelID: String?) -> Self {
        selectedChannelID == activeChannelID ? .alreadyPlaying : .retune
    }
}

/// The Details tab's content, built from the guide data Live TV already holds. Pure, so the
/// rules for missing listings and progress are testable without a view.
struct LiveTVWatchDetails: Equatable {
    struct Airing: Equatable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let start: Date
        let end: Date
        let summary: String?
        let category: String?
        let episode: String?
    }

    let channelName: String
    let channelCategory: String?
    /// The programme airing now, nil when the guide has no listing for this moment.
    let current: Airing?
    /// Elapsed share of the current programme, 0...1.
    let progress: Double?
    /// Listings after the current one, in airing order.
    let upcoming: [Airing]

    static let upcomingLimit = 6
    /// Fits "11:00 PM" at the row's text size, so every Up Next title starts on one line.
    static let upNextTimeColumnWidth: Double = 70
    /// How far ahead the Details tab reads the guide.
    static let lookahead: TimeInterval = 12 * 60 * 60

    static func make(channel: LiveTVChannel, programs: [EPGProgram], fallback: LiveTVProgramPair,
                     now: Date) -> Self {
        let sorted = programs.filter { $0.end > now }.sorted { $0.start < $1.start }
        let currentProgram = sorted.first { $0.start <= now && now < $0.end }
        let current = currentProgram.map(Airing.init)
            ?? fallback.current.flatMap { $0.isCurrent(at: now) ? Airing($0) : nil }
        var upcoming = sorted.filter { $0.start >= (current?.end ?? now) }.map(Airing.init)
        if upcoming.isEmpty, let next = fallback.next, next.startsAt >= now { upcoming = [Airing(next)] }
        let category = channel.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(channelName: channel.name,
                    channelCategory: category.isEmpty ? nil : category,
                    current: current,
                    progress: current.map { progress(start: $0.start, end: $0.end, now: now) },
                    upcoming: Array(upcoming.prefix(upcomingLimit)))
    }

    /// "12 min left", "1 hr 5 min left", rounded up so a programme never reads as over early.
    static func remainingText(end: Date, now: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
    }

    static func progress(start: Date, end: Date, now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }

    /// "30 min", "1 hr", "1 hr 15 min": an Up Next listing's running time.
    static func durationText(start: Date, end: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
        return hoursAndMinutes(minutes)
    }

    /// "Starts in 12 min", "Starts in 1 hr 5 min", or "Starting now" for the next listing.
    static func startsInText(start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "Starting now" }
        return "Starts in \(hoursAndMinutes(minutes))"
    }

    private static func hoursAndMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

/// How the full-screen Live TV player orients itself on iPhone.
///
/// Full screen opened from an inline player (the portrait watch screen or Sports Hub) exists to
/// show the picture larger, so it locks to landscape: a portrait full-screen player is the same
/// 16:9 frame with black above and below. Locking also holds landscape when the device is upright
/// or Portrait Orientation Lock is on, which would otherwise rotate it straight back. Leaving full
/// screen returns to the portrait inline player. The full-screen player opened directly from the
/// channel list rotates freely, as before.
enum LiveTVFullScreenOrientation: Equatable {
    case landscapeLocked
    case rotatesFreely

    static func resolve(isPhone: Bool, isExpandedFromInline: Bool) -> Self {
        isPhone && isExpandedFromInline ? .landscapeLocked : .rotatesFreely
    }

    /// The manual rotate control only makes sense when the player may be either way up.
    var showsRotateControl: Bool { self == .rotatesFreely }
}

extension LiveTVWatchDetails.Airing {
    init(_ program: EPGProgram) {
        self.init(id: program.id, title: program.title, subtitle: program.subtitle, start: program.start,
                  end: program.end, summary: program.summary, category: program.category, episode: program.episode)
    }

    init(_ program: LiveTVProgram) {
        self.init(id: program.id, title: program.title, subtitle: nil, start: program.startsAt,
                  end: program.endsAt, summary: program.summary, category: nil, episode: nil)
    }
}
