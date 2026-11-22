import Foundation
import XCTest
@testable import Silo

/// Build 65: the Picture in Picture start/stop state that outlives one AVKit callback, the tennis
/// lookups that Event Details now shows, and the on-device lifecycle journal.
///
/// The theScore match below is a trimmed copy of the response Build 64 cached on the test iPhone
/// at 2026-11-13 00:32 UTC (WTA Finals, Pegula v Noskova, in progress), read back over USB.
@MainActor
final class KyroBuild65Tests: XCTestCase {

    // MARK: Picture in Picture transition

    /// The Build 62–64 defect: a return to the app while the window was still starting armed a
    /// "stop once started" request. AVKit abandoned that start (did-stop without did-start) and the
    /// request survived, so the next automatic window, from the next swipe to Home, was closed the
    /// moment it appeared.
    func testAnAbandonedStartCannotCloseTheNextAutomaticWindow() {
        var t = PictureInPictureTransition()
        t.willStart(application: .inactive)
        t.stopRequestedWhileStarting(requiresActiveApplication: true)
        t.didStop()                                   // AVKit gave up on that start
        t.willStart(application: .inactive)           // next swipe to Home
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .background), .none)
    }

    func testTheSameSequenceWithFailedToStartAlsoResets() {
        var t = PictureInPictureTransition()
        t.willStart(application: .inactive)
        t.stopRequestedWhileStarting(requiresActiveApplication: true)
        t.failedToStart()
        XCTAssertEqual(t, PictureInPictureTransition())
        t.willStart(application: .inactive)
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .background), .none)
    }

    func testEvenAStaleRequestNeverClosesAWindowOverTheHomeScreen() {
        // No did-stop at all (a callback that never came): the window lands with the app in the
        // background and stays.
        var t = PictureInPictureTransition()
        t.stopRequestedWhileStarting(requiresActiveApplication: true)
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .background), .none)
    }

    func testReturningWhileTheWindowStartsClosesItIntoThePlayer() {
        var t = PictureInPictureTransition()
        t.willStart(application: .inactive)
        t.stopRequestedWhileStarting(requiresActiveApplication: true)
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .active), .stop)
    }

    func testAReturnStillInProgressWaitsForDidBecomeActiveOnce() {
        var t = PictureInPictureTransition()
        t.willStart(application: .inactive)
        t.stopRequestedWhileStarting(requiresActiveApplication: true)
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .inactive), .stopWhenActive)
        XCTAssertTrue(t.applicationDidBecomeActive())
        XCTAssertFalse(t.applicationDidBecomeActive(), "a duplicate did-become-active does nothing")
    }

    func testLeavingAgainBeforeActiveCancelsTheDeferredStop() {
        var t = PictureInPictureTransition()
        t.deferStopUntilActive()
        t.applicationDidEnterBackground()
        XCTAssertFalse(t.applicationDidBecomeActive())
    }

    func testControlStartsAreAnnouncedButALeftoverControlRequestIsNot() {
        var t = PictureInPictureTransition()
        t.controlStartRequested()
        t.willStart(application: .active)
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .active), .announceControlStart)

        var stale = PictureInPictureTransition()
        stale.controlStartRequested()                  // a tap AVKit ignored
        stale.willStart(application: .inactive)        // later: swipe to Home
        XCTAssertEqual(stale.didStart(stopForSourceChange: false, application: .background), .none,
                       "an automatic start must not be handed over as if the button had started it")
    }

    func testSourceChangesAndDeliberateClosesStopWhateverTheAppState() {
        var t = PictureInPictureTransition()
        t.willStart(application: .inactive)
        XCTAssertEqual(t.didStart(stopForSourceChange: true, application: .background), .stop)

        var deliberate = PictureInPictureTransition()
        deliberate.willStart(application: .inactive)
        deliberate.stopRequestedWhileStarting(requiresActiveApplication: true)
        deliberate.stopRequestedWhileStarting(requiresActiveApplication: false)   // a failure close
        XCTAssertEqual(deliberate.didStart(stopForSourceChange: false, application: .background), .stop)
    }

    func testLateAndDuplicateStopsAreHarmless() {
        var t = PictureInPictureTransition()
        t.didStop(); t.didStop(); t.failedToStart()
        XCTAssertEqual(t, PictureInPictureTransition())
        t.willStart(application: .active)
        XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .active), .none)
    }

    func testRepeatedHomeAndReturnCyclesStayStable() {
        // The final 45 s of the Build 64 session: five swipe-Home / return cycles 3–6 s apart.
        var t = PictureInPictureTransition()
        for cycle in 0..<5 {
            t.willStart(application: .inactive)
            XCTAssertEqual(t.didStart(stopForSourceChange: false, application: .background), .none, "cycle \(cycle) keeps its window")
            // Back in the app: the window is closed into the player (an active stop) and stops.
            t.didStop()
        }
        XCTAssertEqual(t, PictureInPictureTransition())
    }

    // MARK: Statistics lookups

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private final class ScriptedProvider: KyroSportsSupplementProviding, @unchecked Sendable {
        let flagKey = "scripted"
        private let lock = NSLock()
        private var next: [KyroSportsSupplementOutcome]
        private(set) var calls = 0
        init(_ outcomes: [KyroSportsSupplementOutcome]) { next = outcomes }
        func isEligible(_ game: KyroSportsGame) -> Bool { game.status.isFinal }
        func supplementalStatistics(for game: KyroSportsGame, existingLabels: [String]) async -> KyroSportsSupplementOutcome {
            lock.withLock {
                calls += 1
                return next.count > 1 ? next.removeFirst() : (next.first ?? .noVerifiedMatch)
            }
        }
    }

    private func game(_ status: KyroGameStatus = .final, start: String = "2026-11-12T13:00:00Z", rawID: String = "401",
                      home: String = "Lorenzo Musetti", away: String = "Ugo Humbert", league: KyroSportLeague = .atp) -> KyroSportsGame {
        func team(_ name: String) -> KyroSportsTeam {
            KyroSportsTeam(id: "espn.\(league.rawValue).\(name)", league: league, abbreviation: String(name.prefix(3)).uppercased(), nickname: name)
        }
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: rawID), league: league,
                              startTime: ISO8601DateFormatter().date(from: start), status: status,
                              home: KyroGameTeam(team: team(home), score: 2), away: KyroGameTeam(team: team(away), score: 1),
                              periods: [.init(id: "s1", label: "S1", homeScore: 6, awayScore: 4)],
                              tournament: "Bybit Stockholm Open", round: "Quarterfinal", isSingles: true)
    }

    private func stats(for g: KyroSportsGame) -> KyroSportsSupplementOutcome {
        .available(.init(gameID: g.id, providerName: "TennisMyLife", providerEventID: "x", rows: [.init(label: "Aces", home: "9", away: "5")]))
    }

    /// Humbert v Musetti, Stockholm QF on 2026-11-12, was final on ESPN but not yet in the data file.
    /// Build 64 remembered "no verified match" for 6 hours; it is now rechecked after 20 minutes.
    func testAJustFinishedMatchIsRecheckedSoonAfterTheDatasetCatchesUp() async {
        let g = game()
        let clock = Clock(ISO8601DateFormatter().date(from: "2026-11-12T16:00:00Z")!)
        let provider = ScriptedProvider([.noVerifiedMatch, stats(for: g)])
        let store = KyroSportsEventDetailStore(supplementProviders: [provider], newsProvider: nil, playerInfoProvider: nil,
                                               flagEnabled: { _ in true }, now: { clock.now })
        await store.loadSupplement(for: g)
        XCTAssertNil(store.supplement)
        XCTAssertEqual(store.supplementLookup, .init(gameID: g.id, outcome: .noVerifiedMatch))
        XCTAssertNil(store.supplementLoadingGameID)
        clock.advance(10 * 60)
        await store.loadSupplement(for: g)
        XCTAssertEqual(provider.calls, 1, "remembered for 20 minutes")
        clock.advance(11 * 60)
        await store.loadSupplement(for: g)
        XCTAssertEqual(provider.calls, 2)
        XCTAssertEqual(store.supplement?.rows.first?.home, "9")
    }

    func testOldMissesAreStillRememberedForHours() {
        let old = game(start: "2026-10-01T13:00:00Z")
        let now = ISO8601DateFormatter().date(from: "2026-11-12T16:00:00Z")!
        XCTAssertEqual(KyroSportsEventDetailStore.supplementTTL(.noVerifiedMatch, game: old, now: now), 6 * 3600)
        XCTAssertEqual(KyroSportsEventDetailStore.supplementTTL(.noVerifiedMatch, game: game(), now: now), 20 * 60)
        XCTAssertEqual(KyroSportsEventDetailStore.supplementTTL(.providerUnavailable, game: old, now: now), 10 * 60)
    }

    func testAnUnreachableSourceKeepsTheShortRetryEvenIfAnotherSaidNotFound() {
        XCTAssertEqual(KyroSportsEventDetailStore.combinedMiss([.noVerifiedMatch, .providerUnavailable]), .providerUnavailable)
        XCTAssertEqual(KyroSportsEventDetailStore.combinedMiss([.providerUnavailable, .ambiguousMatch]), .ambiguousMatch)
        XCTAssertEqual(KyroSportsEventDetailStore.combinedMiss([.noVerifiedMatch, .noVerifiedMatch]), .noVerifiedMatch)
        XCTAssertEqual(KyroSportsEventDetailStore.combinedMiss([]), .noVerifiedMatch)
    }

    func testRapidEventChangesNeverPublishAnotherMatchesLookup() async {
        let a = game(rawID: "A"), b = game(rawID: "B", home: "Taylor Fritz", away: "Holger Rune")
        let provider = ScriptedProvider([stats(for: a)])
        let store = KyroSportsEventDetailStore(supplementProviders: [provider], newsProvider: nil, playerInfoProvider: nil,
                                               flagEnabled: { _ in true })
        async let first: Void = store.loadSupplement(for: a)
        async let second: Void = store.loadSupplement(for: b)
        _ = await (first, second)
        // Whatever finished last, a published lookup only ever carries its own event's statistics.
        if let lookup = store.supplementLookup, case .available(let s) = lookup.outcome { XCTAssertEqual(s.gameID, lookup.gameID) }
        // The provider (deliberately wrong here) answers B with A's rows: they are refused.
        await store.loadSupplement(for: b)
        XCTAssertNotEqual(store.supplement?.gameID, a.id, "B on screen never shows A's statistics")
    }

    func testLiveMatchesAreNotLookedUpAndSayWhy() async {
        let provider = ScriptedProvider([.noVerifiedMatch])
        let store = KyroSportsEventDetailStore(supplementProviders: [provider], newsProvider: nil, playerInfoProvider: nil,
                                               flagEnabled: { _ in true })
        let live = game(.live)
        await store.loadSupplement(for: live)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(KyroTennisStatsMessage.make(status: .live, outcome: nil, isLoading: false)?.title, "Match statistics not available yet")
        XCTAssertNil(KyroTennisStatsMessage.make(status: .scheduled, outcome: nil, isLoading: false))
    }

    func testFinalMatchMessagesNameTheKindOfMiss() {
        XCTAssertEqual(KyroTennisStatsMessage.make(status: .final, outcome: .providerUnavailable, isLoading: false)?.title, "Statistics sources unavailable")
        XCTAssertEqual(KyroTennisStatsMessage.make(status: .final, outcome: .ambiguousMatch, isLoading: false)?.title, "Match statistics not shown")
        XCTAssertEqual(KyroTennisStatsMessage.make(status: .final, outcome: .noVerifiedMatch, isLoading: false)?.title, "Match statistics unavailable")
        XCTAssertEqual(KyroTennisStatsMessage.make(status: .final, outcome: nil, isLoading: true)?.title, "Looking for match statistics…")
        XCTAssertNil(KyroTennisStatsMessage.make(status: .final, outcome: stats(for: game()), isLoading: false))
    }

    // MARK: TennisMyLife cache

    private final class MaxAgeZeroTransport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.withLock { n } }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { n += 1 }
            let header = TennisBuild65Fixtures.header
            return (Data((header + "\n").utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Cache-Control": "public, max-age=0"])!)
        }
    }

    /// TennisMyLife answers `max-age=0` for files it rewrites hourly or daily. Build 64 obeyed it and
    /// downloaded both files on every lookup, spending its 12-requests-per-10-minutes budget.
    func testTennisMyLifeFilesAreReusedForTheirOwnFreshnessDespiteMaxAgeZero() async {
        let transport = MaxAgeZeroTransport()
        let client = TMLMatchStatsClient(transport: transport,
                                         gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                                         cache: ESPNEventDetailResponseCache())
        _ = await client.supplementalStatistics(for: game(), existingLabels: [])
        _ = await client.supplementalStatistics(for: game(rawID: "402", home: "Taylor Fritz", away: "Holger Rune"), existingLabels: [])
        XCTAssertEqual(transport.count, 2, "ongoing and season files once each, then served from the cache")
    }

    // MARK: Player information

    private final class JSONTransport: ESPNTransport, @unchecked Sendable {
        let bodies: [String: String]
        init(_ bodies: [String: String]) { self.bodies = bodies }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            let body = bodies[url.host! + url.path]
            return (Data((body ?? "").utf8), HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }

    private func wtaFinalsGame(status: KyroGameStatus = .live) -> KyroSportsGame {
        game(status, start: "2026-11-12T22:25:00Z", rawID: "wta1", home: "Jessica Pegula", away: "Linda Noskova", league: .wta)
    }

    /// The real device response: every field the card needs was present.
    func testTheDevicesCachedMatchMapsToACompleteCard() async throws {
        let t = JSONTransport(["api.thescore.com/wta/events": TennisBuild65Fixtures.events,
                               "api.thescore.com/wta/events/10547/matches": TennisBuild65Fixtures.matchList,
                               "api.thescore.com/wta/matches/171704": TennisBuild65Fixtures.deviceMatch])
        let client = TheScoreTennisInfoClient(transport: t, gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                                              cache: ESPNEventDetailResponseCache())
        let loaded = await client.playerInfo(for: wtaFinalsGame())
        let info = try XCTUnwrap(loaded)
        XCTAssertEqual(info.home.name, "Jessica Pegula"); XCTAssertEqual(info.home.rank, 5); XCTAssertEqual(info.home.points, 5760)
        XCTAssertEqual(info.away.name, "Linda Noskova"); XCTAssertEqual(info.away.rank, 8); XCTAssertEqual(info.away.country, "Czech Republic")
        XCTAssertEqual(info.meetings, 1); XCTAssertEqual(info.awayHeadToHeadWins, 1)
        XCTAssertEqual(info.home.recent.count, 2)
    }

    /// One malformed element or mistyped field no longer hides every Players card in the event.
    func testOneMalformedMatchOrFieldDoesNotHideTheCard() async throws {
        let list = "[\"not a match\", {\"id\": \"bad\", \"team_1\": 7}, " + TennisBuild65Fixtures.matchList.dropFirst()
        let mistyped = TennisBuild65Fixtures.deviceMatch
            .replacingOccurrences(of: "\"points\":5760", with: "\"points\":\"5760\"")
            .replacingOccurrences(of: "\"age\":32", with: "\"age\":\"thirty-two\"")
        let t = JSONTransport(["api.thescore.com/wta/events": TennisBuild65Fixtures.events,
                               "api.thescore.com/wta/events/10547/matches": String(list),
                               "api.thescore.com/wta/matches/171704": mistyped])
        let client = TheScoreTennisInfoClient(transport: t, gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                                              cache: ESPNEventDetailResponseCache())
        let loaded = await client.playerInfo(for: wtaFinalsGame())
        let info = try XCTUnwrap(loaded)
        XCTAssertEqual(info.home.points, 5760, "a number sent as text still counts")
        XCTAssertNil(info.home.age, "an unreadable field is left out, not the whole card")
        XCTAssertEqual(info.away.rank, 8)
    }

    func testStorePublishesLoadingAndLookedUpStatesForPlayerInfo() async {
        struct Missing: KyroTennisPlayerInfoProviding {
            var flagKey: String { "info" }
            func isEligible(_ game: KyroSportsGame) -> Bool { true }
            func playerInfo(for game: KyroSportsGame) async -> KyroTennisPlayerInfo? { nil }
        }
        let store = KyroSportsEventDetailStore(supplementProviders: [], newsProvider: nil, playerInfoProvider: Missing(), flagEnabled: { _ in true })
        let g = wtaFinalsGame()
        await store.loadPlayerInfo(for: g)
        XCTAssertNil(store.playerInfo)
        XCTAssertEqual(store.playerInfoLookedUpGameID, g.id, "the screen can say none was found instead of showing nothing")
        XCTAssertNil(store.playerInfoLoadingGameID)
        await store.loadPlayerInfo(for: game(rawID: "other"))
        XCTAssertEqual(store.playerInfoLookedUpGameID, game(rawID: "other").id)
    }

    // MARK: Lifecycle journal

    func testJournalLinesAreSingleLineBoundedAndRotate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-journal-\(UUID().uuidString)")
        let saved = KyroLifecycleJournal.directory
        KyroLifecycleJournal.directory = directory
        defer { KyroLifecycleJournal.directory = saved; try? FileManager.default.removeItem(at: directory) }

        let line = KyroLifecycleJournal.line("pip", "did_stop", "restored\nINJECTED", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(line, "1970-01-01T00:00:00.000Z pip did_stop restored INJECTED")
        XCTAssertEqual(KyroLifecycleJournal.clean(String(repeating: "x", count: 500)).count, 160)

        KyroLifecycleJournal.record("app", "launch", "build=65")
        XCTAssertTrue(KyroLifecycleJournal.contents().contains("app launch build=65"))
        let filler = String(repeating: "y", count: 150)
        for _ in 0..<1_400 { KyroLifecycleJournal.record("test", "fill", filler) }
        KyroLifecycleJournal.flush()
        let previous = try XCTUnwrap(KyroLifecycleJournal.previousURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path), "rotated once past the limit")
        let total = KyroLifecycleJournal.contents().utf8.count
        XCTAssertLessThan(total, 2 * KyroLifecycleJournal.maximumBytes + 4096)
        KyroLifecycleJournal.clear()
        XCTAssertEqual(KyroLifecycleJournal.contents(), "")
    }
}

enum TennisBuild65Fixtures {
    static let header = "tourney_id,tourney_name,surface,draw_size,tourney_level,indoor,tourney_date,match_num,winner_id,winner_seed,winner_entry,winner_name,winner_hand,winner_ht,winner_ioc,winner_age,winner_rank,winner_rank_points,loser_id,loser_seed,loser_entry,loser_name,loser_hand,loser_ht,loser_ioc,loser_age,loser_rank,loser_rank_points,score,best_of,round,minutes,w_ace,w_df,w_svpt,w_1stIn,w_1stWon,w_2ndWon,w_SvGms,w_bpSaved,w_bpFaced,l_ace,l_df,l_svpt,l_1stIn,l_1stWon,l_2ndWon,l_SvGms,l_bpSaved,l_bpFaced"

    static let events = #"""
    [{"id":10547,"name":"WTA Finals","start_date":"Sat, 07 Nov 2026 10:00:00 -0000","end_date":"Mon, 16 Nov 2026 00:00:00 -0000"}]
    """#

    static let matchList = #"""
    [{"id":171704,"is_double":false,"team_1":{"id":59068,"player1":{"first_name":"Jessica","last_name":"Pegula"}},"team_2":{"id":59742,"player1":{"first_name":"Linda","last_name":"Noskova"}}}]
    """#

    /// Trimmed from the device's cached response (`fsCachedData/D96428C9…`, 25 KB): first entries of each list, unchanged.
    static let deviceMatch = #"""
    {"id":171704,"is_double":false,"match_date":"Thu, 12 Nov 2026 22:25:00 -0000","status":"in_progress",
     "team_1":{"id":59068,"player1":{"first_name":"Jessica","last_name":"Pegula","country":"USA","plays":"Right","age":32}},
     "team_2":{"id":59742,"player1":{"first_name":"Linda","last_name":"Noskova","country":"Czech Republic","plays":"Right","age":21}},
     "team_1_standing":{"earnings":null,"id":415846,"number_tournaments":null,"place":5,"points":5760,"api_uri":"/wta/standings/415846"},
     "team_2_standing":{"earnings":null,"id":415839,"number_tournaments":null,"place":8,"points":4343,"api_uri":"/wta/standings/415839"},
     "past_meetings_matches":[{"api_uri":"/wta/matches/168058","match_date":"Sun, 21 Jun 2026 15:30:00 -0000","winner":{"id":59742},"result_text":"Noskova d. Pegula","event_name":"Berlin Tennis Open","round_name_abbreviation":"F"}],
     "team_1_last_matches":[{"api_uri":"/wta/matches/171690","match_date":"Tue, 10 Nov 2026 20:00:00 -0000","winner":{"id":59068},"result_text":"Pegula d. Kostyuk","event_name":"WTA Finals","round_name_abbreviation":null},{"api_uri":"/wta/matches/171633","match_date":"Sun, 08 Nov 2026 21:50:00 -0000","winner":{"id":59128},"result_text":"Gauff d. Pegula","event_name":"WTA Finals","round_name_abbreviation":null}],
     "team_2_last_matches":[{"api_uri":"/wta/matches/171691","match_date":"Tue, 10 Nov 2026 22:10:00 -0000","winner":{"id":59742},"result_text":"Noskova d. Gauff","event_name":"WTA Finals","round_name_abbreviation":null}]}
    """#
}
