import Foundation
import Observation
import os
#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit
#endif

/// Opt-in performance instrumentation for device tests (Build 60, corrected in Build 61).
///
/// Off by default. When off, every call below is one Boolean check: no signpost is emitted, no
/// counter is touched and no display link exists. Turn it on in Live TV Settings → Diagnostics;
/// the setting is read once per launch, so relaunch the app after changing it.
///
/// What it records when on:
/// - OSSignposter events and intervals in the Points of Interest category, for Instruments when a
///   debuggable build is attached.
/// - Plain counters (Guide body updates, row builds, EPG publications, detail loads) and the last
///   duration of List/Grid switches, category changes and list reveals.
/// - Frame pacing from a CADisplayLink on the main run loop while the app is active: a frame later
///   than 1.5 intervals is a hitch, and a gap of 250 ms or more is a main-thread stall. Time spent
///   inactive (app switcher, another app, Picture in Picture over another app, a locked screen) is
///   reported as a pause, never as a frame. Build 60 counted the first frame after returning to
///   the app as one 24-second "worst frame".
/// - The same frame pacing again for the time a Guide is on screen, and for the time playback is
///   buffering, so a Guide benchmark and a buffering episode each carry their own numbers.
///
/// The overlay shows those numbers per second. Tap it to copy a text report. It measures this
/// device's run loop; it is not an FPS reading of the GPU and is not a substitute for Instruments.
enum KyroPerformanceDiagnostics {
    static let defaultsKey = "kyro.diagnostics.performanceOverlay"

    /// Fixed for the process so a toggle cannot leave half-started instrumentation behind.
    static let isEnabled: Bool = {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: defaultsKey)
            || ProcessInfo.processInfo.arguments.contains("-kyroPerformanceOverlay")
    }()

    static let signposter = OSSignposter(subsystem: "com.cubbiestream.kyro.performance", category: .pointsOfInterest)

    /// Counts an event and emits a Points of Interest signpost.
    @MainActor
    static func event(_ name: StaticString, _ counter: KyroPerformanceCounter) {
        guard isEnabled else { return }
        signposter.emitEvent(name)
        KyroPerformanceStats.shared.increment(counter)
    }

    /// Counts an event without a signpost, for paths that run per row.
    @MainActor
    static func count(_ counter: KyroPerformanceCounter) {
        guard isEnabled else { return }
        KyroPerformanceStats.shared.increment(counter)
    }

    /// Starts a measured interval. `end` records its duration under `metric`.
    @MainActor
    static func begin(_ name: StaticString, _ metric: KyroPerformanceMetric) -> KyroPerformanceInterval? {
        guard isEnabled else { return nil }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        return KyroPerformanceInterval(name: name, metric: metric, state: state, start: KyroPerformanceClock.now())
    }

    @MainActor
    static func end(_ interval: KyroPerformanceInterval?) {
        guard let interval else { return }
        signposter.endInterval(interval.name, interval.state)
        KyroPerformanceStats.shared.record(interval.metric, milliseconds: (KyroPerformanceClock.now() - interval.start) * 1000)
    }

    /// Records a duration measured elsewhere (for work that crosses actors, where an interval
    /// value would have to travel with it).
    @MainActor
    static func record(_ metric: KyroPerformanceMetric, milliseconds: Double) {
        guard isEnabled else { return }
        KyroPerformanceStats.shared.record(metric, milliseconds: milliseconds)
    }

    /// Build 104: the top-level section on screen (Home, Movies, Series, Sports, Live TV…), so
    /// the report splits frame pacing by section and a slow one stands out.
    @MainActor
    static func section(_ name: String) {
        guard isEnabled else { return }
        KyroPerformanceStats.shared.setSection(name, at: KyroPerformanceClock.now())
    }

    /// Build 104: a Live TV playlist download and import is running. The report gives frame
    /// pacing for that time separately, to show whether it slows the rest of the app.
    @MainActor
    static func catalogRefresh(_ isRunning: Bool) {
        guard isEnabled else { return }
        signposter.emitEvent(isRunning ? "Catalog refresh began" : "Catalog refresh ended")
        KyroPerformanceStats.shared.setCatalogRefresh(isRunning, at: KyroPerformanceClock.now())
    }

    /// A Guide surface became visible or hidden. `source` tells the watch screen's Guide tab and
    /// the full TV Guide apart; Guide frame pacing counts while either is visible.
    @MainActor
    static func guideVisibility(_ source: String, isVisible: Bool) {
        guard isEnabled else { return }
        KyroPerformanceStats.shared.setGuideVisible(source, isVisible, at: KyroPerformanceClock.now())
    }

    /// Playback entered or left the buffering state.
    @MainActor
    static func playbackBuffering(_ isBuffering: Bool) {
        guard isEnabled else { return }
        if isBuffering {
            signposter.emitEvent("Buffering began")
        } else {
            signposter.emitEvent("Buffering ended")
        }
        KyroPerformanceStats.shared.setBuffering(isBuffering, at: KyroPerformanceClock.now())
    }
}

struct KyroPerformanceInterval {
    let name: StaticString
    let metric: KyroPerformanceMetric
    let state: OSSignpostIntervalState
    let start: Double
}

enum KyroPerformanceClock {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

enum KyroPerformanceCounter: String, CaseIterable {
    case watchBody = "Watch body"
    case guideBody = "Guide body"
    case listRowBuild = "List row build"
    case gridRowBuild = "Grid row build"
    case listEntryMiss = "List entry miss"
    case guidePublication = "Guide publish"
    case sportsDetailLoad = "Sports detail load"
    case sportsPinnedRefresh = "Pinned refresh"
}

enum KyroPerformanceMetric: String, CaseIterable {
    case styleSwitch = "List/Grid switch"
    case categoryChange = "Category change"
    case categoryDirectory = "Category data"
    case listReveal = "List reveal"
    case sportsDetailLoad = "Detail load"
    case sportsProviderFetch = "Sports provider fetch"
    case sportsGrouping = "Sports event grouping"
    case sportsFirstVisibleEvent = "Sports first visible event"
    // Build 104
    case liveTVCatalogRefresh = "Live TV catalog refresh"
    case sportsLiveNowReady = "Sports Live Now ready"
    case sportsEventMatch = "Sports event match"
    case iptvStreamRoute = "IPTV stream route"
    case iptvOverview = "IPTV overview"
    case iptvGridPage = "IPTV grid page"
}

/// Frame pacing over some stretch of active time.
struct KyroFrameTally: Equatable {
    var frames = 0
    var hitches = 0
    var stalls = 0
    var worstFrameMilliseconds: Double = 0
    /// Active seconds the tally covers.
    var seconds: Double = 0

    /// A frame later than 1.5 display intervals.
    static let hitchFactor = 1.5
    /// A gap this long means the main thread did not return to its run loop.
    static let stallSeconds = 0.25

    mutating func add(interval: Double, expected: Double) {
        frames += 1
        guard expected > 0 else { return }
        if interval > expected * Self.hitchFactor { hitches += 1 }
        if interval >= Self.stallSeconds { stalls += 1 }
        worstFrameMilliseconds = max(worstFrameMilliseconds, interval * 1000)
    }

    var framesPerSecond: Double { seconds > 0 ? Double(frames) / seconds : 0 }

    var summary: String {
        String(format: "%.0f s, %.0f frames/s, hitches %d, stalls (≥250 ms) %d, worst frame %.0f ms",
               seconds, framesPerSecond, hitches, stalls, worstFrameMilliseconds)
    }
}

/// Totals since launch or the last reset. Not observed: the overlay samples it twice a second.
@MainActor
final class KyroPerformanceStats {
    static let shared = KyroPerformanceStats()

    private(set) var counters: [KyroPerformanceCounter: Int] = [:]
    private(set) var lastDurations: [KyroPerformanceMetric: Double] = [:]
    private(set) var worstDurations: [KyroPerformanceMetric: Double] = [:]
    /// Every frame while the app was active.
    private(set) var all = KyroFrameTally()
    /// Frames while a Guide was on screen.
    private(set) var guide = KyroFrameTally()
    /// Frames while playback was buffering. Healthy pacing here means the run loop was free while
    /// the player waited, so the wait came from the stream or the network rather than this app.
    private(set) var whileBuffering = KyroFrameTally()
    private(set) var bufferingEpisodes = 0
    private(set) var longestBufferingSeconds: Double = 0
    /// Times the app stopped being active, and how long it stayed that way. Excluded from frames.
    private(set) var pauses = 0
    private(set) var pausedSeconds: Double = 0
    private(set) var startedAt: Double
    /// Build 104: frames per top-level section, and while a catalog refresh runs.
    private(set) var sections: [String: KyroFrameTally] = [:]
    private(set) var section: String?
    private(set) var whileCatalogRefresh = KyroFrameTally()
    private(set) var catalogRefreshes = 0
    private var sectionSince: Double?
    private var catalogRefreshSince: Double?
    private var isRefreshingCatalog = false

    private var guideSources: Set<String> = []
    private var isActive = true
    private var pausedAt: Double?
    private var guideSince: Double?
    private var bufferingSince: Double?
    private var isBuffering = false

    init(now: Double = KyroPerformanceClock.now()) {
        startedAt = now
    }

    var frames: Int { all.frames }
    var hitches: Int { all.hitches }
    var stalls: Int { all.stalls }
    var worstFrameMilliseconds: Double { all.worstFrameMilliseconds }
    var isGuideVisible: Bool { !guideSources.isEmpty }

    func increment(_ counter: KyroPerformanceCounter) { counters[counter, default: 0] += 1 }

    func record(_ metric: KyroPerformanceMetric, milliseconds: Double) {
        lastDurations[metric] = milliseconds
        worstDurations[metric] = max(worstDurations[metric] ?? 0, milliseconds)
    }

    /// One display-link callback while active. `interval` is the time since the previous callback
    /// and `expected` the display's frame duration.
    func frame(interval: Double, expected: Double) {
        guard isActive else { return }
        all.add(interval: interval, expected: expected)
        if isGuideVisible { guide.add(interval: interval, expected: expected) }
        if isBuffering { whileBuffering.add(interval: interval, expected: expected) }
        if let section { sections[section, default: KyroFrameTally()].add(interval: interval, expected: expected) }
        if isRefreshingCatalog { whileCatalogRefresh.add(interval: interval, expected: expected) }
    }

    func setSection(_ name: String, at now: Double) {
        guard name != section else { return }
        if let section, let since = sectionSince { sections[section, default: KyroFrameTally()].seconds += max(0, now - since) }
        section = name
        sectionSince = isActive ? now : nil
    }

    func setCatalogRefresh(_ running: Bool, at now: Double) {
        guard running != isRefreshingCatalog else { return }
        isRefreshingCatalog = running
        if running {
            catalogRefreshes += 1
            if isActive { catalogRefreshSince = now }
        } else {
            if let since = catalogRefreshSince { whileCatalogRefresh.seconds += max(0, now - since) }
            catalogRefreshSince = nil
        }
    }

    /// The app left the active state. Frames stop counting until `resume`.
    func pause(at now: Double) {
        guard isActive else { return }
        closeTimedSpans(at: now)
        isActive = false
        pausedAt = now
        pauses += 1
    }

    func resume(at now: Double) {
        guard !isActive else { return }
        if let pausedAt { pausedSeconds += max(0, now - pausedAt) }
        pausedAt = nil
        isActive = true
        openTimedSpans(at: now)
    }

    func setGuideVisible(_ source: String, _ visible: Bool, at now: Double) {
        let wasVisible = isGuideVisible
        if visible { guideSources.insert(source) } else { guideSources.remove(source) }
        guard wasVisible != isGuideVisible, isActive else { return }
        if isGuideVisible {
            guideSince = now
        } else if let since = guideSince {
            guide.seconds += max(0, now - since)
            guideSince = nil
        }
    }

    func setBuffering(_ buffering: Bool, at now: Double) {
        guard buffering != isBuffering else { return }
        isBuffering = buffering
        if buffering {
            bufferingEpisodes += 1
            if isActive { bufferingSince = now }
            episodeStart = now
        } else {
            if let since = bufferingSince { whileBuffering.seconds += max(0, now - since) }
            bufferingSince = nil
            if let episodeStart { longestBufferingSeconds = max(longestBufferingSeconds, now - episodeStart) }
            episodeStart = nil
        }
    }

    private var episodeStart: Double?

    private func closeTimedSpans(at now: Double) {
        if let since = guideSince { guide.seconds += max(0, now - since) }
        guideSince = nil
        if let since = bufferingSince { whileBuffering.seconds += max(0, now - since) }
        bufferingSince = nil
        if let section, let since = sectionSince { sections[section, default: KyroFrameTally()].seconds += max(0, now - since) }
        sectionSince = nil
        if let since = catalogRefreshSince { whileCatalogRefresh.seconds += max(0, now - since) }
        catalogRefreshSince = nil
    }

    private func openTimedSpans(at now: Double) {
        if isGuideVisible { guideSince = now }
        if isBuffering { bufferingSince = now }
        if section != nil { sectionSince = now }
        if isRefreshingCatalog { catalogRefreshSince = now }
    }

    func reset(at now: Double = KyroPerformanceClock.now()) {
        counters = [:]
        lastDurations = [:]
        worstDurations = [:]
        all = KyroFrameTally()
        guide = KyroFrameTally()
        whileBuffering = KyroFrameTally()
        bufferingEpisodes = isBuffering ? 1 : 0
        longestBufferingSeconds = 0
        pauses = 0
        pausedSeconds = 0
        startedAt = now
        pausedAt = isActive ? nil : now
        guideSince = isActive && isGuideVisible ? now : nil
        bufferingSince = isActive && isBuffering ? now : nil
        episodeStart = isBuffering ? now : nil
        sections = [:]
        sectionSince = isActive && section != nil ? now : nil
        whileCatalogRefresh = KyroFrameTally()
        catalogRefreshes = isRefreshingCatalog ? 1 : 0
        catalogRefreshSince = isActive && isRefreshingCatalog ? now : nil
    }

    /// Elapsed time minus time spent inactive.
    func activeSeconds(at now: Double) -> Double {
        let ongoingPause = pausedAt.map { max(0, now - $0) } ?? 0
        return max(0, now - startedAt - pausedSeconds - ongoingPause)
    }

    /// A tally with any span still open counted up to `now`.
    func tally(_ base: KyroFrameTally, openedAt since: Double?, now: Double) -> KyroFrameTally {
        var tally = base
        if let since { tally.seconds += max(0, now - since) }
        return tally
    }

    func report(now: Double = KyroPerformanceClock.now()) -> String {
        let elapsed = max(0.001, now - startedAt)
        let active = max(0.001, activeSeconds(at: now))
        var overall = all
        overall.seconds = active
        let guideTally = tally(guide, openedAt: guideSince, now: now)
        let bufferingTally = tally(whileBuffering, openedAt: bufferingSince, now: now)
        var lines = [String(format: "Kyro performance report, %.0f s window, %.0f s active", elapsed, active),
                     String(format: "Inactive (not measured): %d times, %.0f s", pauses, elapsed - active),
                     "All active time: \(overall.summary)"]
        lines.append(guideTally.seconds > 0 ? "Guide on screen: \(guideTally.summary)"
                                            : "Guide on screen: not shown during this window")
        if bufferingEpisodes > 0 {
            lines.append(String(format: "Buffering: %d episodes, longest %.1f s", bufferingEpisodes, longestBufferingSeconds))
            lines.append("While buffering: \(bufferingTally.summary)")
        } else {
            lines.append("Buffering: none")
        }
        for name in sections.keys.sorted() {
            let open = name == section ? sectionSince : nil
            lines.append("Section \(name): \(tally(sections[name] ?? KyroFrameTally(), openedAt: open, now: now).summary)")
        }
        if catalogRefreshes > 0 {
            lines.append("Live TV catalog refreshes: \(catalogRefreshes)\(isRefreshingCatalog ? " (running)" : "")")
            lines.append("While a catalog refresh ran: \(tally(whileCatalogRefresh, openedAt: catalogRefreshSince, now: now).summary)")
        }
        for counter in KyroPerformanceCounter.allCases {
            let value = counters[counter] ?? 0
            lines.append(String(format: "%@: %d (%.1f/s active)", counter.rawValue, value, Double(value) / active))
        }
        for metric in KyroPerformanceMetric.allCases {
            if let last = lastDurations[metric] {
                lines.append(String(format: "%@: last %.0f ms, worst %.0f ms", metric.rawValue, last, worstDurations[metric] ?? last))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The short Guide and buffering lines for the overlay.
    func overlaySummary(now: Double = KyroPerformanceClock.now()) -> [String] {
        let guideTally = tally(guide, openedAt: guideSince, now: now)
        var lines: [String] = []
        if guideTally.seconds > 0 {
            lines.append(String(format: "guide %.0fs  hitch %d  stalls %d  worst %.0fms%@", guideTally.seconds,
                                guideTally.hitches, guideTally.stalls, guideTally.worstFrameMilliseconds,
                                isGuideVisible ? "" : " (hidden)"))
        }
        if bufferingEpisodes > 0 {
            let bufferingTally = tally(whileBuffering, openedAt: bufferingSince, now: now)
            lines.append(String(format: "buffering %d×  longest %.1fs  %.0f frames/s while buffering%@",
                                bufferingEpisodes, longestBufferingSeconds, bufferingTally.framesPerSecond,
                                isBuffering ? "  NOW" : ""))
        }
        if pauses > 0 {
            lines.append(String(format: "inactive %d×, %.0fs (excluded)", pauses, now - startedAt - activeSeconds(at: now)))
        }
        return lines
    }
}

#if os(iOS)
/// Samples frame pacing on the main run loop while any overlay is on screen. One display link
/// for the process: overlays under and over a full-screen cover share it, so frames count once.
/// The link and the counting stop while the app is not active.
@MainActor
final class KyroFramePacingMonitor: NSObject {
    static let shared = KyroFramePacingMonitor()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var users = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard KyroPerformanceDiagnostics.isEnabled else { return }
        users += 1
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        observeLifecycle()
        if UIApplication.shared.applicationState != .active {
            KyroPerformanceStats.shared.pause(at: KyroPerformanceClock.now())
            link.isPaused = true
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        link?.invalidate()
        link = nil
        last = 0
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func observeLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { KyroFramePacingMonitor.shared.becameInactive() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { KyroFramePacingMonitor.shared.becameActive() }
        })
    }

    private func becameInactive() {
        KyroPerformanceStats.shared.pause(at: KyroPerformanceClock.now())
        link?.isPaused = true
        last = 0
    }

    private func becameActive() {
        // The next callback sets a fresh baseline instead of measuring the time away.
        last = 0
        link?.isPaused = false
        KyroPerformanceStats.shared.resume(at: KyroPerformanceClock.now())
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let expected = link.targetTimestamp - link.timestamp
        KyroPerformanceStats.shared.frame(interval: link.timestamp - last, expected: expected > 0 ? expected : 1.0 / 60)
    }
}

/// A small corner readout. Its own once-every-half-second timer drives it; it reads no app state.
struct KyroPerformanceOverlay: View {
    @State private var text = "Performance overlay starting…"
    @State private var previous: (frames: Int, hitches: Int, counters: [KyroPerformanceCounter: Int], active: Double)?
    @State private var copied = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if copied { Text("Copied").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).padding(4) }
            }
            .onTapGesture {
                UIPasteboard.general.string = KyroPerformanceStats.shared.report()
                copied = true
            }
            .onLongPressGesture {
                KyroPerformanceStats.shared.reset()
                previous = nil
            }
            .accessibilityLabel("Performance overlay. Tap to copy the report, press and hold to reset.")
            .task {
                KyroFramePacingMonitor.shared.start()
                defer { KyroFramePacingMonitor.shared.stop() }
                while !Task.isCancelled {
                    sample()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }

    private func sample() {
        let stats = KyroPerformanceStats.shared
        let now = KyroPerformanceClock.now()
        let active = stats.activeSeconds(at: now)
        defer {
            previous = (stats.frames, stats.hitches, stats.counters, active)
            if copied { copied = false }
        }
        // Rates use active time, so a sample spanning time away from the app is not diluted.
        guard let previous, active - previous.active > 0.05 else { return }
        let seconds = active - previous.active
        func rate(_ counter: KyroPerformanceCounter) -> Int {
            Int((Double((stats.counters[counter] ?? 0) - (previous.counters[counter] ?? 0)) / seconds).rounded())
        }
        let frames = Int((Double(stats.frames - previous.frames) / seconds).rounded())
        var lines = [
            "frames/s \(frames)  hitch/s \(Int((Double(stats.hitches - previous.hitches) / seconds).rounded()))  stalls \(stats.stalls)  worst \(Int(stats.worstFrameMilliseconds))ms",
            "watch \(rate(.watchBody))/s  guide \(rate(.guideBody))/s  list rows \(rate(.listRowBuild))/s  grid rows \(rate(.gridRowBuild))/s",
            "entry miss \(rate(.listEntryMiss))/s  EPG pub \(stats.counters[.guidePublication] ?? 0)  detail \(stats.counters[.sportsDetailLoad] ?? 0)",
        ]
        lines += stats.overlaySummary(now: now)
        let durations = KyroPerformanceMetric.allCases.compactMap { metric in
            stats.lastDurations[metric].map { "\(metric.rawValue) \(Int($0))ms" }
        }
        if !durations.isEmpty { lines.append(durations.joined(separator: "  ")) }
        text = lines.joined(separator: "\n")
    }
}

extension View {
    /// Adds the performance overlay when diagnostics are enabled for this launch.
    @ViewBuilder
    func kyroPerformanceOverlay() -> some View {
        if KyroPerformanceDiagnostics.isEnabled {
            overlay(alignment: .bottomLeading) {
                KyroPerformanceOverlay()
                    .padding(.leading, 8)
                    .padding(.bottom, 96)
            }
        } else {
            self
        }
    }

    /// Reports this Guide surface's visibility to the performance overlay. No effect when off.
    @ViewBuilder
    func kyroGuidePerformanceScope(_ source: String, isVisible: Bool) -> some View {
        if KyroPerformanceDiagnostics.isEnabled {
            onAppear { KyroPerformanceDiagnostics.guideVisibility(source, isVisible: isVisible) }
                .onChange(of: isVisible) { _, visible in KyroPerformanceDiagnostics.guideVisibility(source, isVisible: visible) }
                .onDisappear { KyroPerformanceDiagnostics.guideVisibility(source, isVisible: false) }
        } else {
            self
        }
    }
}
#endif
