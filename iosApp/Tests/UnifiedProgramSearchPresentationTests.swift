import Foundation
import XCTest
@testable import Silo

/// How TV program results read in Search: sections, live/upcoming from the clock, local times,
/// spoken labels and source-specific empty states.
final class UnifiedProgramSearchPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri 15 Jan 2027 08:00 UTC
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let english = Locale(identifier: "en_US")

    func testSectionsKeepChannelsAndProgramsSeparateUnderEachFilter() {
        typealias P = UnifiedProgramSearchPresentation
        XCTAssertEqual(P.sectionTitle(.moviesAndTV, filter: .all), "Movies & TV")
        XCTAssertEqual(P.sectionTitle(.liveTV, filter: .all), "Live TV")
        XCTAssertEqual(P.sectionTitle(.programs, filter: .all), "TV Programs")
        XCTAssertEqual(P.sectionTitle(.liveTV, filter: .liveTV), "Live TV")
        XCTAssertEqual(P.sectionTitle(.programs, filter: .liveTV), "TV Programs")
        XCTAssertEqual(UnifiedSearchFilter.all.seeAllFilter(for: .programs), .liveTV, "See All programs opens Live TV")
        XCTAssertEqual(UnifiedSearchFilter.allCases, [.all, .moviesAndTV, .liveTV], "no new filter")
        XCTAssertFalse(UnifiedSearchFilter.moviesAndTV.showsLiveTV, "Movies & TV shows neither channels nor programs")
    }

    func testStatusComesFromTheClockAtTheBoundaries() {
        let result = program(startOffset: 0, duration: 3_600)
        typealias P = UnifiedProgramSearchPresentation
        XCTAssertEqual(P.state(of: result, at: now.addingTimeInterval(-1)), .upcoming)
        XCTAssertEqual(P.state(of: result, at: now), .live)
        XCTAssertEqual(P.state(of: result, at: now.addingTimeInterval(3_599)), .live)
        XCTAssertEqual(P.state(of: result, at: now.addingTimeInterval(3_600)), .ended)
        XCTAssertTrue(result.isLive(at: result.start), "the start boundary is live")
        XCTAssertFalse(result.isLive(at: result.end), "the end boundary is ended")
        XCTAssertEqual(P.badge(for: .live), "LIVE NOW")
        XCTAssertEqual(P.badge(for: .upcoming), "UPCOMING")
        // The flag stored at search time never overrides the clock.
        let searchedWhileUpcoming = program(startOffset: 60, duration: 600, wasLive: false)
        XCTAssertEqual(P.state(of: searchedWhileUpcoming, at: now.addingTimeInterval(120)), .live)
    }

    func testProgramsThatEndWhileShownDropOutInOrder() {
        let results = [program("a", startOffset: -600, duration: 900), program("b", startOffset: 0, duration: 60),
                       program("c", startOffset: 300, duration: 600)]
        let later = UnifiedProgramSearchPresentation.visible(results, at: now.addingTimeInterval(120))
        XCTAssertEqual(later.map(\.programID), ["a", "c"])
        XCTAssertEqual(UnifiedProgramSearchPresentation.visible(results, at: now.addingTimeInterval(400)).map(\.programID), ["c"])
    }

    func testTimesAreLocalWithTheWeekdayOnlyForAnotherDay() {
        let today = program(startOffset: 12 * 3_600, duration: 3_600) // 20:00–21:00 UTC
        XCTAssertEqual(normalized(UnifiedProgramSearchPresentation.timeRange(today, now: now, calendar: utc, locale: english)),
                       "8:00 PM – 9:00 PM")
        let tomorrow = program(startOffset: 26 * 3_600, duration: 1_800) // Sat 10:00–10:30 UTC
        XCTAssertEqual(normalized(UnifiedProgramSearchPresentation.timeRange(tomorrow, now: now, calendar: utc, locale: english)),
                       "Sat 10:00 AM – 10:30 AM")

        var tokyo = utc
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(normalized(UnifiedProgramSearchPresentation.timeRange(today, now: now, calendar: tokyo, locale: english)),
                       "Sat 5:00 AM – 6:00 AM", "the viewer's time zone decides both the times and the day")
    }

    func testSpokenLabelFollowsTheGuide() {
        let live = program(startOffset: -600, duration: 3_600, title: "Cup Final", subtitle: "Second Half")
        XCTAssertEqual(normalized(UnifiedProgramSearchPresentation.accessibilityLabel(live, now: now, calendar: utc, locale: english)),
                       "Cup Final, Second Half, Sports One, 7:50 AM to 8:50 AM, On now")
        let upcoming = program(startOffset: 3_600, duration: 1_800, title: "Late News")
        XCTAssertEqual(normalized(UnifiedProgramSearchPresentation.accessibilityLabel(upcoming, now: now, calendar: utc, locale: english)),
                       "Late News, Sports One, 9:00 AM to 9:30 AM, Upcoming")
        let nextDay = program(startOffset: 26 * 3_600, duration: 1_800, title: "Saturday Match")
        XCTAssertEqual(normalized(UnifiedProgramSearchPresentation.accessibilityLabel(nextDay, now: now, calendar: utc, locale: english)),
                       "Saturday Match, Sports One, Sat 10:00 AM to 10:30 AM, Upcoming")
    }

    func testEmptyStatesAreSourceSpecificAndDistinct() {
        typealias P = UnifiedProgramSearchPresentation
        XCTAssertEqual(P.emptyMessage(for: .init(phase: .loaded, resultCount: 0))?.text, "No matching TV programs")
        XCTAssertEqual(P.emptyMessage(for: .init(phase: .loading))?.text, "Searching TV programs…")
        XCTAssertEqual(P.emptyMessage(for: .init(phase: .loading, message: "Loading the TV guide…"))?.text, "Loading the TV guide…")
        XCTAssertEqual(P.emptyMessage(for: .idle)?.text, "Type at least 2 characters to search TV programs.")
        let unavailable = ["No TV guide is available.", "The TV guide is out of date.",
                           "TV program search isn't available for this guide."]
        let texts = unavailable.map { P.emptyMessage(for: .init(phase: .unavailable, message: $0))?.text }
        XCTAssertEqual(texts, unavailable)
        XCTAssertEqual(Set(texts + [P.emptyMessage(for: .init(phase: .loaded))?.text,
                                    P.emptyMessage(for: .init(phase: .loading, message: "Loading the TV guide…"))?.text]).count, 5)
        XCTAssertEqual(P.emptyMessage(for: .init(phase: .failed, message: "Boom"))?.text, "Boom")
    }

    func testPreviewAndPagingStayBounded() {
        XCTAssertEqual(UnifiedSearchResultsSection.combinedPreviewLimit, 6)
        XCTAssertEqual(UnifiedSearchResultsSection.nextVisibleLimit(current: 6, total: EPGProgramSearchIndex.defaultResultLimit), 66)
        XCTAssertEqual(UnifiedSearchResultsSection.nextVisibleLimit(current: 246, total: EPGProgramSearchIndex.defaultResultLimit), 300)
        XCTAssertEqual(UnifiedSearchResultsSection.nextVisibleLimit(current: 300, total: 300), 300)
    }

    private func program(_ id: String = "p", startOffset: TimeInterval, duration: TimeInterval,
                         title: String = "Program", subtitle: String? = nil, wasLive: Bool = false) -> UnifiedProgramSearchResult {
        let start = now.addingTimeInterval(startOffset)
        return UnifiedProgramSearchResult(id: "c|\(id)", programID: id, channelID: "c", channelKey: "c",
                                          channelName: "Sports One", channelOrdinal: 0, logoURL: nil, title: title,
                                          subtitle: subtitle, start: start, end: start.addingTimeInterval(duration),
                                          wasLiveAtSearch: wasLive)
    }

    /// Foundation may use narrow no-break spaces in times ("8:00 PM").
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
