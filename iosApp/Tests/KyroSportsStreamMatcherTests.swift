import Foundation
import XCTest
@testable import Silo

final class KyroSportsStreamMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testExactProgrammeMatchIsHighConfidence() throws {
        let game = game(away: "Boston Celtics", home: "Los Angeles Lakers", league: .nba)
        let channel = channel("nba", name: "NBA HD", guideID: "guide.nba")
        let guide = try guide(programTitle: "NBA: Boston Celtics at Los Angeles Lakers", channelID: "guide.nba")
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: [channel], guide: guide)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.matches.first?.channel.id, channel.id)
        XCTAssertTrue(result.matches.first?.reasons.contains { $0.lowercased().contains("both teams") } == true)
    }

    func testAliasMatchAndSharedGuideIdentifierRetainBothPlayableChannels() throws {
        let game = game(away: "San Francisco 49ers", home: "New York Giants", league: .nfl)
        let channels = [channel("one", name: "NFL East", guideID: "shared"), channel("two", name: "NFL East HD", guideID: "shared")]
        let guide = try guide(programTitle: "NFL: NY Giants vs SF 49ers", channelID: "shared")
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: channels, guide: guide)
        XCTAssertEqual(result.confidence, .medium, "duplicate variants require a picker")
        XCTAssertEqual(Set(result.matches.map(\.channel.id)), Set(channels.map(\.id)))
    }

    func testConflictingProgrammeTimesAndGenericSportsChannelDoNotBecomeHigh() throws {
        let game = game(away: "Duke Blue Devils", home: "North Carolina Tar Heels", league: .collegeFootball)
        let generic = channel("generic", name: "ESPN Sports", guideID: "generic")
        let other = channel("other", name: "College Sports", guideID: "other")
        let guide = try guide(programTitle: "College Football: Alabama vs Georgia", channelID: "generic")
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: [generic, other], guide: guide)
        XCTAssertNotEqual(result.confidence, .high)
        XCTAssertTrue(result.matches.isEmpty || result.matches.allSatisfy { $0.confidence != .high })
    }

    func testStaleGuideDisablesHighConfidenceAndProvidesManualQuery() throws {
        let game = game(away: "New York Yankees", home: "Los Angeles Dodgers", league: .mlb)
        let channel = channel("mlb", name: "MLB", guideID: "mlb")
        let stale = try guide(programTitle: "MLB: New York Yankees at Los Angeles Dodgers", channelID: "mlb", fetchedAt: now.addingTimeInterval(-48 * 60 * 60))
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: [channel], guide: stale)
        XCTAssertTrue(result.guideWasStale)
        XCTAssertNotEqual(result.confidence, .high)
        XCTAssertTrue(result.manualSearchQuery.contains("Yankees"))
    }

    func testNoMatchFallsBackToManualSearch() throws {
        let game = game(away: "Green Bay Packers", home: "Chicago Bears", league: .nfl)
        let channel = channel("news", name: "Local News", guideID: "news")
        let guide = try guide(programTitle: "Weather", channelID: "news")
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: [channel], guide: guide)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.manualSearchQuery.contains("Packers"))
    }

    func testSQLiteBackedGuideIsQueriedForNonResidentChannel() throws {
        let game = game(away: "Boston Celtics", home: "Los Angeles Lakers", league: .nba)
        let channel = channel("nba", name: "NBA HD", guideID: "guide.nba")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let start = formatter.string(from: now.addingTimeInterval(-15 * 60))
        let end = formatter.string(from: now.addingTimeInterval(3 * 60 * 60))
        let xml = "<tv><channel id=\"guide.nba\"><display-name>NBA HD</display-name></channel><programme channel=\"guide.nba\" start=\"\(start)\" stop=\"\(end)\"><title>NBA: Boston Celtics at Los Angeles Lakers</title></programme></tv>"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("KyroSportsMatcher-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: destination) }
        let built = try EPGSQLiteBuilder.build(xml: Data(xml.utf8), filter: nil, limits: EPGLimits(), fetchedAt: now,
                                                providerID: UUID(), fingerprint: Data(repeating: 0, count: EPGSourceFingerprint.length),
                                                destination: destination, readPolicy: .cachedOnly)
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: [channel],
                                                                guide: EPGIndex(sqlite: built.index, statistics: built.statistics))
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.matches.first?.program?.title, "NBA: Boston Celtics at Los Angeles Lakers")
    }

    func testCancellationReturnsExplicitCancelledResult() async throws {
        let game = game(away: "Boston Celtics", home: "Los Angeles Lakers", league: .nba)
        let channels = (0..<1_024).map { channel("c\($0)", name: "NBA \($0)", guideID: "missing") }
        let task = Task { () -> KyroSportsStreamMatchResult in
            KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: channels, guide: nil)
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.indexWasCancelled || result.matches.isEmpty)
    }

    // MARK: Build 37 — Sam Houston at Jacksonville State (device report)

    /// ESPN event 401871075 as Kyro maps it: SHSU @ JXST, 7 PM ET, CBSSN.
    private func samHoustonAtJaxState() -> KyroSportsGame {
        let away = KyroSportsTeam(id: "espn.collegeFootball.2534", league: .collegeFootball, abbreviation: "SHSU",
                                  nickname: "Bearkats", location: "Sam Houston",
                                  alternateNames: ["Sam Houston Bearkats", "Sam Houston"])
        let home = KyroSportsTeam(id: "espn.collegeFootball.55", league: .collegeFootball, abbreviation: "JXST",
                                  nickname: "Gamecocks", location: "Jacksonville State",
                                  alternateNames: ["Jacksonville State Gamecocks", "Jax State"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "401871075"),
                              league: .collegeFootball, startTime: now, status: .scheduled,
                              home: KyroGameTeam(team: home), away: KyroGameTeam(team: away), broadcast: "CBSSN")
    }

    private struct Listing {
        let channel: String
        let guideID: String?
        let title: String
        var summary: String? = nil
        var category: String? = nil
        var startOffset: TimeInterval = 0
    }

    private func catalog(_ listings: [Listing]) throws -> (channels: [LiveTVChannel], guide: EPGIndex) {
        let channels = listings.enumerated().map { index, listing in
            channel("c\(index)", name: listing.channel, guideID: listing.guideID)
        }
        var guideChannels: [EPGChannel] = []
        var programs: [EPGProgram] = []
        for listing in listings {
            guard let id = listing.guideID, !listing.title.isEmpty else { continue }
            if !guideChannels.contains(where: { $0.id == id }) {
                guideChannels.append(EPGChannel(id: id, displayNames: [listing.channel]))
            }
            let start = now.addingTimeInterval(listing.startOffset)
            programs.append(EPGProgram(channelID: id, start: start, end: start.addingTimeInterval(3.5 * 60 * 60),
                                       title: listing.title, summary: listing.summary, category: listing.category))
        }
        let guide = try EPGIndex(document: EPGDocument(channels: guideChannels, programs: programs),
                                 fetchedAt: now, now: now, limits: EPGLimits())
        return (channels, guide)
    }

    /// The candidates reported from Build 36, plus generic NCAA channels.
    private var observedFalsePositives: [Listing] {
        [
            Listing(channel: "NCAA Football 01", guideID: "ncaa.01",
                    title: "College Football: Iowa vs. Northwestern (Replay)",
                    summary: "Big Ten football from Kinnick Stadium. Later tonight Jacksonville State hosts Sam Houston State.",
                    category: "Sports"),
            Listing(channel: "Sports Plus 2", guideID: "sp.2", title: "Southern Indiana vs. Evansville",
                    summary: "Ohio Valley Conference action between two in-state rivals.", category: "Football"),
            Listing(channel: "Texas HS Football", guideID: "hs.tx",
                    title: "High School Football: Houston Lamar vs. Jacksonville Sandalwood", category: "Football"),
            Listing(channel: "NCAA Football 05", guideID: nil, title: ""),
            Listing(channel: "College Sports HD", guideID: nil, title: ""),
            Listing(channel: "ESPN College Extra 3", guideID: "espn.cx3", title: "College Football Live",
                    category: "Football")
        ]
    }

    func testObservedFalsePositivesAreRejectedAndRealBroadcastIsHigh() throws {
        let game = samHoustonAtJaxState()
        let real = Listing(channel: "CBS Sports Network HD", guideID: "cbssn",
                           title: "College Football: Sam Houston at Jacksonville State", category: "Football")
        let (channels, guide) = try catalog(observedFalsePositives + [real])
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now.addingTimeInterval(-3600)),
                                                                channels: channels, guide: guide)
        XCTAssertEqual(result.matches.map(\.channel.name), ["CBS Sports Network HD"])
        XCTAssertEqual(result.confidence, .high)
        XCTAssertNotNil(result.highConfidenceMatch)
        XCTAssertTrue(result.matches[0].reasons.contains("Channel matches the listed broadcaster"))
    }

    func testOnlyFalsePositivesYieldHonestNoMatch() throws {
        let (channels, guide) = try catalog(observedFalsePositives)
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                channels: channels, guide: guide)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertTrue(result.matches.isEmpty, "no generic or unrelated channel fills the picker")
        XCTAssertEqual(result.manualSearchSuggestions, ["Sam Houston", "Jacksonville State", "CBSSN"])
    }

    func testAliasesAbbreviationsAndReversedOrderMatch() throws {
        for title in ["Jax State vs. Sam Houston State", "NCAAF: SHSU @ JXST",
                      "Sam Houston Bearkats at Jacksonville State Gamecocks (Live)",
                      "Jacksonville St. vs Sam Houston"] {
            let (channels, guide) = try catalog([Listing(channel: "Regional Sports 4", guideID: "rs4", title: title)])
            let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                    channels: channels, guide: guide)
            XCTAssertEqual(result.confidence, .high, title)
        }
    }

    func testWeakOrPartialEvidenceIsNeverHigh() throws {
        let cases: [(Listing, KyroSportsStreamMatchConfidence?)] = [
            // Mascots alone repeat across schools.
            (Listing(channel: "Regional 1", guideID: "r1", title: "Bearkats at Gamecocks"), .medium),
            // One school, on time, clearly this sport: a lead, not a launch.
            (Listing(channel: "Regional 2", guideID: "r2", title: "Jacksonville State Gamecocks Football"), .medium),
            // Right matchup, guide slot 50 minutes late: shown, not launched.
            (Listing(channel: "Regional 3", guideID: "r3", title: "Sam Houston at Jacksonville State",
                     startOffset: 50 * 60), .medium),
            // Matchup only in a generic programme's description.
            (Listing(channel: "Regional 4", guideID: "r4", title: "College Football",
                     summary: "Sam Houston at Jacksonville State from AmFirst Stadium."), .medium)
        ]
        for (listing, expected) in cases {
            let (channels, guide) = try catalog([listing])
            let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                    channels: channels, guide: guide)
            XCTAssertEqual(result.matches.first?.confidence, expected, listing.title)
            XCTAssertNil(result.highConfidenceMatch, listing.title)
        }
    }

    func testConflictingTeamsOtherSportsAndReplaysAreRejected() throws {
        for title in ["Jacksonville State vs. Liberty", "Sam Houston at Kennesaw State",
                      "College Basketball: Sam Houston vs. Jacksonville State",
                      "Sam Houston at Jacksonville State (Replay)", "Sam Houston at Jacksonville State Highlights",
                      "Pregame: Sam Houston at Jacksonville State"] {
            let (channels, guide) = try catalog([Listing(channel: "Regional 9", guideID: "r9", title: title)])
            let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                    channels: channels, guide: guide)
            XCTAssertTrue(result.matches.isEmpty, title)
        }
    }

    func testTimeSupportsButNeverCreatesAMatch() throws {
        let (late, lateGuide) = try catalog([Listing(channel: "Regional 5", guideID: "r5",
                                                     title: "Sam Houston at Jacksonville State", startOffset: 100 * 60)])
        XCTAssertTrue(KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                 channels: late, guide: lateGuide).matches.isEmpty,
                      "a slot 100 minutes after kickoff is a later replay")
        let (onTime, onTimeGuide) = try catalog([Listing(channel: "NCAA Football 1", guideID: "n1",
                                                         title: "NCAA Football", category: "Football")])
        XCTAssertTrue(KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                 channels: onTime, guide: onTimeGuide).matches.isEmpty,
                      "a generic programme at kickoff is not evidence")
    }

    func testSubstringsOfOtherSchoolsDoNotMatch() throws {
        let houston = KyroSportsTeam(id: "h", league: .collegeFootball, abbreviation: "HOU", nickname: "Cougars", location: "Houston")
        let iowa = KyroSportsTeam(id: "i", league: .collegeFootball, abbreviation: "IOWA", nickname: "Hawkeyes", location: "Iowa")
        let northwestern = KyroSportsTeam(id: "n", league: .collegeFootball, abbreviation: "NU", nickname: "Wildcats", location: "Northwestern")
        let game = KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "x"),
                                  league: .collegeFootball, startTime: now, status: .scheduled,
                                  home: KyroGameTeam(team: northwestern), away: KyroGameTeam(team: iowa))
        let (channels, guide) = try catalog([
            Listing(channel: "A", guideID: "a", title: "Iowa State vs. Northwestern State"),
            Listing(channel: "B", guideID: "b", title: "Iowa at Northwestern")
        ])
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: channels, guide: guide)
        XCTAssertEqual(result.matches.map(\.channel.name), ["B"])

        let houstonGame = KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "y"),
                                         league: .collegeFootball, startTime: now, status: .scheduled,
                                         home: KyroGameTeam(team: samHoustonAtJaxState().home.team),
                                         away: KyroGameTeam(team: houston))
        let (other, otherGuide) = try catalog([Listing(channel: "C", guideID: "c", title: "Sam Houston at Jacksonville State")])
        XCTAssertTrue(KyroSportsStreamMatcher.matchSynchronously(request: .init(game: houstonGame, now: now),
                                                                 channels: other, guide: otherGuide).matches.isEmpty,
                      "\"Houston\" inside \"Sam Houston\" is a different school")
    }

    func testEventChannelNameWithoutGuideIsAPickerLeadOnly() throws {
        let (channels, guide) = try catalog([
            Listing(channel: "NCAAF 07: Sam Houston @ Jacksonville State 7:00 PM ET", guideID: nil, title: ""),
            Listing(channel: "NCAAF 08: Liberty @ Jacksonville State 3:30 PM ET", guideID: nil, title: "")
        ])
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: samHoustonAtJaxState(), now: now),
                                                                channels: channels, guide: guide)
        XCTAssertEqual(result.matches.map(\.channel.name), ["NCAAF 07: Sam Houston @ Jacksonville State 7:00 PM ET"])
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertNil(result.highConfidenceMatch)
    }

    func testTennisSurnamesMatchAndOtherTourIsRejected() throws {
        func player(_ name: String, _ league: KyroSportLeague) -> KyroSportsTeam {
            KyroSportsTeam(id: name, league: league, abbreviation: String(name.prefix(3)).uppercased(), nickname: name)
        }
        let final = KyroSportsGame(id: KyroGameID(provider: "espn", league: .atp, rawID: "186507"), league: .atp,
                                   startTime: now, status: .scheduled,
                                   home: KyroGameTeam(team: player("Ben Shelton", .atp)),
                                   away: KyroGameTeam(team: player("Carlos Alcaraz", .atp)),
                                   tournament: "Rolex Paris Masters", round: "Final", isSingles: true)
        let (channels, guide) = try catalog([
            Listing(channel: "Tennis Channel", guideID: "tc", title: "ATP Paris Masters Final: Alcaraz v Shelton"),
            Listing(channel: "Tennis 2", guideID: "t2", title: "WTA Finals: Pegula v Gauff"),
            Listing(channel: "Tennis 3", guideID: "t3", title: "Paris Doubles Final: Alcaraz/Lopez v Shelton/Paul")
        ])
        let result = KyroSportsStreamMatcher.matchSynchronously(request: .init(game: final, now: now), channels: channels, guide: guide)
        XCTAssertEqual(result.matches.map(\.channel.name), ["Tennis Channel"])
        XCTAssertEqual(result.confidence, .high)
    }

    private func game(away: String, home: String, league: KyroSportLeague) -> KyroSportsGame {
        let awayTeam = KyroSportsTeam(id: "a", league: league, abbreviation: String(away.prefix(3)).uppercased(), nickname: away, location: nil)
        let homeTeam = KyroSportsTeam(id: "h", league: league, abbreviation: String(home.prefix(3)).uppercased(), nickname: home, location: nil)
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: UUID().uuidString), league: league,
                              startTime: now, status: .scheduled,
                              home: KyroGameTeam(team: homeTeam), away: KyroGameTeam(team: awayTeam))
    }

    private func channel(_ id: String, name: String, guideID: String?) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: guideID, name: name, streamURL: URL(string: "https://example.com/\(id).m3u8")!, logoURL: nil, category: "Sports")
    }

    private func guide(programTitle: String, channelID: String, fetchedAt: Date? = nil) throws -> EPGIndex {
        let document = EPGDocument(channels: [EPGChannel(id: channelID, displayNames: ["Sports"])], programs: [
            EPGProgram(channelID: channelID, start: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(3 * 60 * 60), title: programTitle)
        ])
        return try EPGIndex(document: document, fetchedAt: fetchedAt ?? now, now: now, limits: EPGLimits())
    }

}
