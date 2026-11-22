import CoreGraphics
import Foundation

/// The guide's bounded time window and the mapping from instants to horizontal positions.
///
/// Positions come from absolute time, so a programme keeps its real width across a
/// daylight-saving change. Ticks are aligned to local half hours, including zones with 30- and
/// 45-minute offsets.
struct LiveTVGuideTimeline: Equatable, Sendable {
    struct Tick: Identifiable, Equatable, Sendable {
        let date: Date
        /// True on the local hour, for a stronger label.
        let isHour: Bool
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    static let slot: TimeInterval = 30 * 60

    let start: Date
    let end: Date
    let pointsPerMinute: CGFloat
    let timeZone: TimeZone

    init(now: Date, timeZone: TimeZone, lookBack: TimeInterval = 60 * 60, lookAhead: TimeInterval = 12 * 60 * 60,
         pointsPerMinute: CGFloat = 4) {
        let start = Self.halfHourFloor(now.addingTimeInterval(-lookBack), in: timeZone)
        let slots = ((now.addingTimeInterval(lookAhead).timeIntervalSince(start)) / Self.slot).rounded(.up)
        self.start = start
        end = start.addingTimeInterval(max(1, slots) * Self.slot)
        self.pointsPerMinute = pointsPerMinute
        self.timeZone = timeZone
    }

    var interval: DateInterval { DateInterval(start: start, end: end) }
    var width: CGFloat { x(for: end) }

    /// Horizontal position of `date`, clamped to the window.
    func x(for date: Date) -> CGFloat {
        let minutes = min(max(date.timeIntervalSince(start), 0), end.timeIntervalSince(start)) / 60
        return CGFloat(minutes) * pointsPerMinute
    }

    var ticks: [Tick] {
        stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: Self.slot).map { seconds in
            let date = Date(timeIntervalSince1970: seconds)
            let local = Int(seconds) + timeZone.secondsFromGMT(for: date)
            return Tick(date: date, isHour: local % 3_600 == 0)
        }
    }

    /// True once the window no longer leaves room ahead of `now`, so the guide should re-anchor.
    func needsRebuild(at now: Date) -> Bool {
        now < start || end.timeIntervalSince(now) < 3 * 60 * 60
    }

    /// The scroll offset that shows `now` with `history` of the past before it.
    func scrollOffset(showing now: Date, history: TimeInterval = 30 * 60) -> CGFloat {
        max(0, x(for: now) - CGFloat(history / 60) * pointsPerMinute)
    }

    static func halfHourFloor(_ date: Date, in timeZone: TimeZone) -> Date {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: date))
        let local = date.timeIntervalSince1970 + offset
        let floored = (local / slot).rounded(.down) * slot
        return Date(timeIntervalSince1970: floored - offset)
    }
}

/// The slice of the timeline a row needs to build, quantized to whole hours of scroll offset so
/// that scrolling changes it rarely and a row builds only the programmes near the screen instead
/// of everything in the 13-hour window.
///
/// `edge` is the span the viewport's leading edge can cross while the quantized offset is
/// unchanged; only programmes overlapping it can straddle that edge and need their title pinned.
struct LiveTVGuideVisibleSpan: Equatable, Sendable {
    /// Timeline x positions to build, one hour behind and one hour past the viewport.
    let render: ClosedRange<CGFloat>
    /// Timeline x positions the leading edge can reach before the span next changes.
    let edge: ClosedRange<CGFloat>

    /// - Parameters:
    ///   - offsetX: how far the grid is scrolled, which is also the timeline x at the leading edge.
    ///   - viewportWidth: the scroll view's width.
    ///   - bucketWidth: the quantization step, one hour of timeline.
    init(offsetX: CGFloat, viewportWidth: CGFloat, bucketWidth: CGFloat) {
        let bucket = max(0, (max(offsetX, 0) / bucketWidth).rounded(.down))
        let lower = bucket * bucketWidth
        render = max(0, lower - bucketWidth) ... lower + 2 * bucketWidth + max(viewportWidth, 0)
        edge = lower ... lower + bucketWidth
    }

    func renders(_ cell: LiveTVGuideCell) -> Bool {
        cell.x <= render.upperBound && cell.x + cell.width >= render.lowerBound
    }

    func pinsTitle(of cell: LiveTVGuideCell) -> Bool {
        cell.x <= edge.upperBound && cell.x + cell.width >= edge.lowerBound
    }
}

enum LiveTVGuideProgramState: Equatable, Sendable {
    case past
    case current
    case upcoming

    init(_ program: EPGProgram, at now: Date) {
        if program.end <= now { self = .past }
        else if program.start <= now { self = .current }
        else { self = .upcoming }
    }
}

/// What a tap on a programme does. Only the airing programme tunes; anything else shows details.
enum LiveTVGuideAction: Equatable, Sendable {
    case tune
    case showDetails

    init(_ program: EPGProgram, at now: Date) {
        self = LiveTVGuideProgramState(program, at: now) == .current ? .tune : .showDetails
    }
}

/// One programme placed on the timeline, clipped to the window.
struct LiveTVGuideCell: Identifiable, Equatable, Sendable {
    let program: EPGProgram
    let x: CGFloat
    let width: CGFloat
    /// True when the programme began before the window, so its leading edge is cut off.
    let startsBeforeWindow: Bool
    var id: String { program.id }

    static let minimumWidth: CGFloat = 3

    static func cells(for programs: [EPGProgram], in timeline: LiveTVGuideTimeline) -> [LiveTVGuideCell] {
        programs.compactMap { program in
            guard program.end > timeline.start, program.start < timeline.end else { return nil }
            let x = timeline.x(for: program.start)
            let width = max(minimumWidth, timeline.x(for: program.end) - x)
            return LiveTVGuideCell(program: program, x: x, width: width, startsBeforeWindow: program.start < timeline.start)
        }
    }
}

/// Which screen the guide shows instead of, or above, its grid.
enum LiveTVGuideContentState: Equatable, Sendable {
    case setup
    case loading
    case failed(String)
    case noChannels
    case noMatches
    case ready

    static func resolve(hasProviders: Bool, isLoading: Bool, errorMessage: String?, channelCount: Int,
                        visibleCount: Int) -> Self {
        guard hasProviders else { return .setup }
        guard channelCount > 0 else {
            if isLoading { return .loading }
            if let errorMessage { return .failed(errorMessage) }
            return .noChannels
        }
        // A failed refresh keeps the last channels visible; the banner reports it.
        return visibleCount == 0 ? .noMatches : .ready
    }

    /// The one-line notice above a ready grid, if any.
    static func banner(errorMessage: String?, catalogNotice: String? = nil, guideMessage: String?,
                       isGuideStale: Bool, isGuideLoading: Bool) -> String? {
        // Hard import failures first, then soft channel-cap notices, then guide status.
        if let errorMessage { return errorMessage }
        if let catalogNotice { return catalogNotice }
        if isGuideLoading { return nil }
        if let guideMessage { return guideMessage }
        return isGuideStale ? "Program guide unavailable" : nil
    }
}
