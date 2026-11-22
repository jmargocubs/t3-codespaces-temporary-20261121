import Foundation
import XCTest
@testable import Silo

/// Build 39: the shared stream row used by the stream picker and Other Streams.
@MainActor
final class KyroSportsStreamPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String, _ name: String? = nil, logo: Bool = false) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: name ?? "Stream \(id)", streamURL: URL(string: "https://example.com/\(id).ts")!,
                      logoURL: logo ? URL(string: "https://example.com/\(id).png") : nil, category: "Events")
    }

    private func match(_ id: String, eligible: Bool = true, source: KyroSportsStreamMatch.Source = .channelName,
                       program: EPGProgram? = nil, name: String? = nil) -> KyroSportsStreamMatch {
        KyroSportsStreamMatch(id: id, channel: channel(id, name), program: program, confidence: .medium, score: 60,
                              reasons: ["Both teams named in the guide title", "Starts on time", "Score 71"],
                              isStale: false, source: source, isAutoPlayEligible: eligible)
    }

    private func programme(_ title: String, channel: String = "g") -> EPGProgram {
        EPGProgram(channelID: channel, start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3 * 3600), title: title)
    }

    private func game() -> KyroSportsGame {
        let away = KyroSportsTeam(id: "a", league: .nfl, abbreviation: "KC", nickname: "Chiefs", location: "Kansas City")
        let home = KyroSportsTeam(id: "h", league: .nfl, abbreviation: "BUF", nickname: "Bills", location: "Buffalo")
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .nfl, rawID: "1"), league: .nfl, startTime: now,
                              status: .live, home: KyroGameTeam(team: home), away: KyroGameTeam(team: away))
    }

    // MARK: Grouping

    func testStrongMatchesComeFirstAndNetworkChannelsLastAndCollapsed() {
        let sections = KyroSportsStreamSection.make(
            matches: [match("weak", eligible: false), match("strong"), match("search", source: .manual)],
            broadcasters: [match("espn", eligible: false, source: .broadcaster)],
            status: { _ in .untested }, currentChannelID: nil)
        XCTAssertEqual(sections.map(\.kind), [.eventMatches, .possibleMatches, .networkChannels])
        XCTAssertEqual(sections[0].rows.map(\.channelID), ["strong"])
        XCTAssertEqual(sections[1].rows.map(\.channelID), ["weak", "search"])
        XCTAssertEqual(sections[2].rows.map(\.channelID), ["espn"])
        XCTAssertFalse(sections[2].startsExpanded, "unconfirmed network channels do not crowd the picker")
        XCTAssertTrue(sections[0].startsExpanded)
    }

    func testNoGenericChannelsAreAddedAndDuplicatesCollapse() {
        let sections = KyroSportsStreamSection.make(matches: [match("a"), match("a")], broadcasters: [match("a", source: .broadcaster)],
                                                    status: { _ in .untested }, currentChannelID: nil)
        XCTAssertEqual(sections.flatMap(\.rows).map(\.channelID), ["a"])
        XCTAssertTrue(KyroSportsStreamSection.make(matches: [], broadcasters: [], status: { _ in .untested },
                                                   currentChannelID: nil).isEmpty)
    }

    func testNetworkChannelsExpandOnceOneWasTried() {
        let sections = KyroSportsStreamSection.make(matches: [], broadcasters: [match("espn", source: .broadcaster)],
                                                    status: { _ in .failed }, currentChannelID: nil)
        XCTAssertTrue(sections[0].startsExpanded)
    }

    func testNetworkSectionShowsSixInitiallyAndSearchesBoundedExpandedRows() {
        let candidates = (0..<12).map { match("n\($0)", eligible: false, source: .broadcaster,
                                              name: $0 == 10 ? "Universo 4K" : "NBC Local \($0)") }
        let section = KyroSportsStreamSection.make(matches: [match("n0")], broadcasters: candidates,
                                                   status: { _ in .untested }, currentChannelID: nil)
            .first { $0.kind == .networkChannels }!
        XCTAssertEqual(section.rows.count, 11, "a verified match is not repeated in network channels")
        XCTAssertEqual(section.visibleNetworkRows(showAll: false).count, 6)
        XCTAssertEqual(section.visibleNetworkRows(showAll: true).count, 11)
        XCTAssertEqual(section.visibleNetworkRows(showAll: true, query: "universo").map(\.channelID), ["n10"])
    }

    // MARK: Status and evidence

    func testMetadataMatchAndPlaybackResultAreDistinct() {
        let untested = KyroSportsStreamRowModel(match: match("a"), status: .untested, isCurrent: false)
        let played = KyroSportsStreamRowModel(match: match("a"), status: .verified, isCurrent: false)
        XCTAssertEqual(untested.status, .eventMatch)
        XCTAssertEqual(untested.statusLabel, "Event match")
        XCTAssertEqual(played.status, .played)
        XCTAssertEqual(played.statusLabel, "Played")
        XCTAssertEqual(untested.evidence, played.evidence, "evidence describes metadata, not playback")
        XCTAssertFalse(played.accessibilityLabel.lowercased().contains("verified"),
                       "starting a stream is not proof of what it shows")
    }

    func testStatusLabelsForEveryState() {
        func row(_ m: KyroSportsStreamMatch, _ s: KyroSportsStreamStatus, current: Bool = false) -> KyroSportsStreamRowModel.Status {
            KyroSportsStreamRowModel(match: m, status: s, isCurrent: current).status
        }
        XCTAssertEqual(row(match("a"), .verified, current: true), .nowPlaying)
        XCTAssertEqual(row(match("a"), .untested, current: true), .nowPlaying)
        XCTAssertEqual(row(match("a"), .connecting), .connecting)
        XCTAssertEqual(row(match("a"), .failed, current: true), .didNotPlay)
        XCTAssertEqual(row(match("a", eligible: false), .untested), .possibleMatch)
        XCTAssertEqual(row(match("a", source: .manual), .untested), .fromSearch)
        XCTAssertEqual(row(match("a", source: .broadcaster), .untested), .unconfirmed)
    }

    func testCurrentStreamIsHighlightedAndOnlyReselectableAfterFailing() {
        let playing = KyroSportsStreamRowModel(match: match("a"), status: .verified, isCurrent: true)
        let failed = KyroSportsStreamRowModel(match: match("a"), status: .failed, isCurrent: true)
        XCTAssertTrue(playing.isCurrent)
        XCTAssertFalse(playing.isSelectable)
        XCTAssertEqual(playing.accessibilityHint, "Playing now")
        XCTAssertTrue(failed.isSelectable, "a failed stream can be tried again")
        XCTAssertEqual(failed.accessibilityHint, "Tries this stream again")
    }

    func testScoringNotesAreReplacedByOneShortReason() {
        let guide = KyroSportsStreamRowModel(match: match("a", source: .guide, program: programme("Chiefs at Bills")),
                                             status: .untested, isCurrent: false)
        XCTAssertEqual(guide.evidence, "Guide lists this game")
        XCTAssertFalse(guide.accessibilityLabel.contains("Score 71"))
        XCTAssertEqual(KyroSportsStreamRowModel(match: match("b"), status: .untested, isCurrent: false).evidence,
                       "Channel name lists this game")
        XCTAssertEqual(KyroSportsStreamRowModel(match: match("c", source: .broadcaster), status: .untested, isCurrent: false).evidence,
                       "Network listed for this game")
    }

    // MARK: Names, logos and programmes

    func testLongNamesKeepTheFullNameForAccessibility() {
        let long = "USA | DAZN  Event   07:   Kansas City Chiefs @ Buffalo Bills 11/08 08:20 PM ET (Backup Feed)"
        let row = KyroSportsStreamRowModel(match: match("a", name: long), status: .untested, isCurrent: false)
        XCTAssertEqual(row.displayName, "USA | DAZN Event 07: Kansas City Chiefs @ Buffalo Bills 11/08 08:20 PM ET (Backup Feed)")
        XCTAssertEqual(row.fullName, long)
        XCTAssertTrue(row.accessibilityLabel.hasPrefix(long))
    }

    func testMatchedListingWinsOverCurrentProgrammeAndLogoPassesThrough() {
        let withListing = KyroSportsStreamRowModel(match: match("a", source: .guide, program: programme("Chiefs at Bills")),
                                                   status: .untested, isCurrent: false, currentProgramme: programme("News"))
        XCTAssertEqual(withListing.programmeTitle, "Chiefs at Bills")
        let named = KyroSportsStreamRowModel(match: match("b"), status: .untested, isCurrent: false, currentProgramme: programme("NFL Live"))
        XCTAssertEqual(named.programmeTitle, "NFL Live")
        XCTAssertNil(KyroSportsStreamRowModel(match: match("c"), status: .untested, isCurrent: false).programmeTitle)
        let logo = KyroSportsStreamMatch(id: "l", channel: channel("l", logo: true), program: nil, confidence: .medium, score: 1,
                                         reasons: [], isStale: false)
        XCTAssertEqual(KyroSportsStreamRowModel(match: logo, status: .untested, isCurrent: false).logoURL?.lastPathComponent, "l.png")
    }

    // MARK: Other Streams switching

    func testSwitchingStreamsKeepsTheEventAndMovesTheHighlight() {
        let driver = KyroSportsPlaybackTestDriver()
        let coordinator = KyroSportsPlaybackCoordinator(scheduler: KyroSportsPlaybackTestScheduler())
        coordinator.driver = driver
        let game = game()
        var result = KyroSportsStreamMatchResult(confidence: .medium, matches: [match("a"), match("b")], manualSearchQuery: "",
                                                 guideWasStale: false, indexWasCancelled: false)
        result.autoPlayCandidates = result.matches
        let token = coordinator.beginSearching(game)
        coordinator.start(result, for: game, token: token, allowsAutomaticPlayback: true)
        driver.state = .playing
        coordinator.sessionDidChange()
        XCTAssertEqual(coordinator.phase, .presented)

        func rows() -> [KyroSportsStreamRowModel] {
            let context = coordinator.context!
            return KyroSportsStreamSection.make(matches: context.alternatives, broadcasters: context.broadcasters,
                                                status: { context.status(of: $0) },
                                                currentChannelID: context.currentChannelID).flatMap(\.rows)
        }
        XCTAssertEqual(rows().map(\.status), [.nowPlaying, .eventMatch])

        XCTAssertTrue(coordinator.switchTo(match("b")))
        XCTAssertEqual(rows().map(\.status), [.played, .connecting])
        driver.state = .failed
        coordinator.sessionDidChange()
        XCTAssertEqual(rows().map(\.status), [.played, .didNotPlay])
        XCTAssertTrue(rows()[1].isSelectable, "recovery after a failed stream")
        XCTAssertEqual(coordinator.context?.game.id, game.id, "the event context survives switching")

        XCTAssertTrue(coordinator.switchTo(match("a")))
        driver.state = .playing
        coordinator.sessionDidChange()
        XCTAssertEqual(rows().map(\.status), [.nowPlaying, .didNotPlay])
    }
}
