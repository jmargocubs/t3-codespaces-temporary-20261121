import Foundation
import XCTest
@testable import Silo

/// Build 38: event-named IPTV channels, DAZN-style listings, auto-play eligibility and
/// broadcaster separation, on top of the Build 37 matcher rules.
final class KyroSportsEventChannelMatchingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func michiganStateAtMichigan(broadcast: String? = "FOX", status: KyroGameStatus = .live) -> KyroSportsGame {
        let away = KyroSportsTeam(id: "espn.collegeFootball.127", league: .collegeFootball, abbreviation: "MSU",
                                  nickname: "Spartans", location: "Michigan State",
                                  alternateNames: ["Michigan State Spartans", "Michigan St"])
        let home = KyroSportsTeam(id: "espn.collegeFootball.130", league: .collegeFootball, abbreviation: "MICH",
                                  nickname: "Wolverines", location: "Michigan",
                                  alternateNames: ["Michigan Wolverines"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "401752900"),
                              league: .collegeFootball, startTime: now, status: status,
                              home: KyroGameTeam(team: home), away: KyroGameTeam(team: away), broadcast: broadcast)
    }

    private func samHoustonAtJaxState() -> KyroSportsGame {
        let away = KyroSportsTeam(id: "espn.collegeFootball.2534", league: .collegeFootball, abbreviation: "SHSU",
                                  nickname: "Bearkats", location: "Sam Houston",
                                  alternateNames: ["Sam Houston Bearkats", "Sam Houston"])
        let home = KyroSportsTeam(id: "espn.collegeFootball.55", league: .collegeFootball, abbreviation: "JVST",
                                  nickname: "Gamecocks", location: "Jacksonville State",
                                  alternateNames: ["Jacksonville State Gamecocks", "Jax State"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "401871075"),
                              league: .collegeFootball, startTime: now, status: .live,
                              home: KyroGameTeam(team: home), away: KyroGameTeam(team: away), broadcast: "CBSSN")
    }

    private func buccaneersAtBears(broadcast: String = "NBC/Peacock/Universo") -> KyroSportsGame {
        let away = KyroSportsTeam(id: "tb", league: .nfl, abbreviation: "TB", nickname: "Buccaneers", location: "Tampa Bay")
        let home = KyroSportsTeam(id: "chi", league: .nfl, abbreviation: "CHI", nickname: "Bears", location: "Chicago")
        let kickoff = ISO8601DateFormatter().date(from: "2026-11-09T01:20:00Z")!
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .nfl, rawID: "bucs-bears-20261108"),
                              league: .nfl, startTime: kickoff, status: .live,
                              home: KyroGameTeam(team: home), away: KyroGameTeam(team: away), broadcast: broadcast)
    }

    private func channel(_ id: String, _ name: String, category: String = "Sports", guideID: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: guideID, name: name, streamURL: URL(string: "https://example.com/\(id).ts")!,
                      logoURL: nil, category: category)
    }

    private func match(_ game: KyroSportsGame, _ channels: [LiveTVChannel], guide: EPGIndex? = nil) -> KyroSportsStreamMatchResult {
        KyroSportsStreamMatcher.matchSynchronously(request: .init(game: game, now: now), channels: channels, guide: guide)
    }

    private func guide(_ listings: [(id: String, title: String)], fetchedAt: Date? = nil) throws -> EPGIndex {
        let channels = Set(listings.map(\.id)).map { EPGChannel(id: $0, displayNames: [$0]) }
        let programs = listings.map {
            EPGProgram(channelID: $0.id, start: now.addingTimeInterval(-10 * 60), end: now.addingTimeInterval(3.5 * 3600), title: $0.title)
        }
        return try EPGIndex(document: EPGDocument(channels: channels, programs: programs),
                            fetchedAt: fetchedAt ?? now, now: now, limits: EPGLimits())
    }

    // MARK: Event channel names

    func testDAZNStyleEventChannelIsAnAutoPlayCandidateWithoutGuide() {
        let event = channel("dazn", "DAZN UK: Michigan State @ Michigan", category: "UK | DAZN")
        let result = match(michiganStateAtMichigan(), [event, channel("news", "Sky News")])
        XCTAssertEqual(result.matches.map(\.channel.id), ["dazn"])
        XCTAssertEqual(result.matches.first?.source, .channelName)
        XCTAssertEqual(result.autoPlayCandidates.map(\.channel.id), ["dazn"], "the name identifies the event")
    }

    func testCollegeHoopsFullSchoolNamesAndGuideTitlesMatchWithoutGenericNetworkFalsePositive() {
        let away = KyroSportsTeam(id: "duke", league: .collegeBasketballMen, abbreviation: "DUKE", nickname: "Blue Devils", location: "Duke",
                                  alternateNames: ["Duke Blue Devils"])
        let home = KyroSportsTeam(id: "unc", league: .collegeBasketballMen, abbreviation: "UNC", nickname: "Tar Heels", location: "North Carolina",
                                  alternateNames: ["North Carolina Tar Heels"])
        let game = KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeBasketballMen, rawID: "cbb-1"),
                                  league: .collegeBasketballMen, startTime: now, status: .live,
                                  home: KyroGameTeam(team: home), away: KyroGameTeam(team: away), broadcast: "ESPN2")
        let eventChannel = channel("event", "ESPN2: Duke Blue Devils vs North Carolina Tar Heels", category: "NCAAM")
        XCTAssertEqual(match(game, [eventChannel]).matches.first?.channel.id, "event")
        XCTAssertTrue(match(game, [channel("generic", "ESPN")]).matches.isEmpty)
        let guideResult = match(game, [channel("guide", "ESPN2", guideID: "espn")],
                                guide: try? guide([("espn", "Duke vs. North Carolina" )]))
        XCTAssertEqual(guideResult.matches.count, 1)
    }

    func testMatchupSpellingsAndReversedOrderAllMatch() {
        for name in ["NCAAF: Michigan State vs Michigan", "Michigan State at Michigan", "Michigan vs. Michigan State",
                     "NCAAF 03: (12) Michigan State vs (3) Michigan", "Michigan St @ Michigan Wolverines",
                     "Michigan State Spartans x Michigan Wolverines"] {
            let result = match(michiganStateAtMichigan(), [channel("c", name, category: "USA | NCAAF")])
            XCTAssertEqual(result.matches.count, 1, name)
            XCTAssertEqual(result.autoPlayCandidates.count, 1, name)
        }
    }

    /// Build 37 read "@ 12:00 PM" as a second contest and rejected the channel.
    func testKickoffTimeAfterTheMatchupIsNotAConflict() {
        let result = match(michiganStateAtMichigan(), [
            channel("c", "NCAAF 03: Michigan State vs Michigan @ 12:00 PM ET", category: "USA | NCAAF")
        ])
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertTrue(result.matches[0].isAutoPlayEligible)
    }

    func testAbbreviationEventChannelMatches() {
        let result = match(samHoustonAtJaxState(), [channel("c", "SHSU @ JXST", category: "USA | NCAAF")])
        XCTAssertEqual(result.matches.map(\.channel.id), ["c"])
        XCTAssertTrue(result.matches[0].isAutoPlayEligible)
    }

    func testIndexedCandidateTermsCoverAbbreviationsAndAlternateNames() {
        let terms = KyroSportsStreamMatcher.candidateSearchTerms(for: samHoustonAtJaxState())
        XCTAssertTrue(terms.contains("SHSU"))
        XCTAssertTrue(terms.contains("JVST"))
        XCTAssertTrue(terms.contains("jxst"))
        XCTAssertTrue(terms.contains("Jax State"))
        XCTAssertTrue(terms.contains("Jacksonville State Gamecocks"))
    }

    func testCategorySupportsButNeverProvesAMatch() {
        let named = match(michiganStateAtMichigan(), [channel("c", "Michigan State vs Michigan", category: "USA | NCAAF")])
        XCTAssertTrue(named.matches.first?.reasons.contains("Listed under USA | NCAAF") == true)

        let generic = match(michiganStateAtMichigan(), [
            channel("a", "NCAAF 01", category: "USA | NCAAF"), channel("b", "NCAAF 02", category: "USA | NCAAF")
        ])
        XCTAssertTrue(generic.matches.isEmpty, "a league group alone is not the event")
        XCTAssertTrue(generic.autoPlayCandidates.isEmpty)
    }

    func testConflictingMatchupsAreRejected() {
        let result = match(michiganStateAtMichigan(), [
            channel("a", "DAZN UK: Ohio State @ Michigan"),
            channel("b", "NCAAF: Michigan State vs Iowa"),
            channel("c", "Michigan State @ Michigan", category: "USA | NCAAB"),
            channel("d", "Michigan State @ Michigan (Replay)"),
            channel("e", "Michigan State @ Michigan Highlights"),
            channel("f", "Michigan State @ Michigan", category: "Replays"),
            channel("g", "HS Football: Michigan State @ Michigan")
        ])
        XCTAssertTrue(result.matches.isEmpty, result.matches.map(\.channel.name).joined(separator: ", "))
    }

    func testChannelNameDateForAnotherDayIsRejected() {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day], from: now)
        let lastWeek = calendar.dateComponents([.month, .day], from: now.addingTimeInterval(-7 * 86_400))
        let stale = channel("old", "NCAAF: Michigan State @ Michigan \(lastWeek.month!)/\(lastWeek.day!)")
        let current = channel("new", "NCAAF: Michigan State @ Michigan \(today.month!)/\(today.day!)")
        let result = match(michiganStateAtMichigan(), [stale, current])
        XCTAssertEqual(result.matches.map(\.channel.id), ["new"])
        XCTAssertTrue(result.matches[0].reasons.contains("Channel name date matches the event"))
    }

    func testWeakAbbreviationWithoutLeagueContextIsALeadOnly() {
        let result = match(michiganStateAtMichigan(), [channel("c", "MSU @ MICH", category: "Events")])
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertTrue(result.autoPlayCandidates.isEmpty, "\"MSU\" names several schools")
    }

    // MARK: Broadcasters

    func testGenericBroadcastersAreSeparateAndNeverAutoPlayed() throws {
        let result = match(michiganStateAtMichigan(broadcast: "FOX"), [
            channel("fox", "FOX"), channel("foxhd", "FOX HD"), channel("dazn", "DAZN 1"), channel("espn", "ESPN")
        ])
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.autoPlayCandidates.isEmpty)
        XCTAssertEqual(Set(result.possibleBroadcasters.map(\.channel.id)), ["fox", "foxhd"])
        XCTAssertTrue(result.possibleBroadcasters.allSatisfy { $0.source == .broadcaster && !$0.isAutoPlayEligible })
    }

    func testEventMatchOutranksAndExcludesBroadcasterEntry() throws {
        let guide = try guide([(id: "fox.us", title: "College Football: Michigan State at Michigan")])
        let result = match(michiganStateAtMichigan(broadcast: "FOX"), [
            channel("fox", "FOX", guideID: "fox.us"), channel("foxsd", "FOX SD East")
        ], guide: guide)
        XCTAssertEqual(result.matches.map(\.channel.id), ["fox"])
        XCTAssertEqual(result.possibleBroadcasters.map(\.channel.id), ["foxsd"], "a matched channel is not listed twice")
    }

    func testBuccaneersBearsFindsNBCAndUniversoVariantsWithoutEPGButNeverAutoPlaysThem() {
        let channels = [channel("affiliate", "NBC Chicago WMAQ"), channel("nbc4k", "NBC4K"),
                        channel("nbcuhd", "NBC UHD"), channel("nbcfhd", "NBC FHD"),
                        channel("nbc1080", "NBC 1080p"), channel("nbchd", "NBC HD"),
                        channel("regionalPrefix", "USA | NBC"),
                        channel("universo", "Universo HD", category: "Spanish"),
                        channel("nbcnews", "NBCNews")]
        let result = match(buccaneersAtBears(), channels)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.autoPlayCandidates.isEmpty)
        XCTAssertEqual(result.possibleBroadcasters.map(\.channel.id),
                       ["nbc4k", "nbcuhd", "nbcfhd", "nbc1080", "nbchd", "universo", "regionalPrefix", "affiliate"])
        XCTAssertFalse(result.possibleBroadcasters.contains { $0.channel.name == "Peacock" },
                       "a streaming service is not synthesized into the IPTV catalog")
        XCTAssertFalse(result.possibleBroadcasters.contains { $0.channel.id == "nbcnews" }, "NBC must be a whole token")
        XCTAssertTrue(result.possibleBroadcasters.allSatisfy { $0.source == .broadcaster && !$0.isAutoPlayEligible })
    }

    func testBroadcasterAliasesAreBoundarySafeAndSpanishNetworkIsNotInferredFromNBCAlone() {
        let channels = [channel("universo", "NBC Universo UHD"), channel("universo4k", "Universo4K"),
                        channel("univision", "Univision HD"), channel("nbc", "NBC HD")]
        let both = match(buccaneersAtBears(broadcast: "NBC, Peacock & Universo"), channels)
        XCTAssertEqual(Set(both.possibleBroadcasters.map(\.channel.id)), ["universo", "universo4k", "nbc"])
        XCTAssertEqual(both.possibleBroadcasters.count, 3, "a channel matching NBC and Universo appears only once")
        let nbcOnly = match(buccaneersAtBears(broadcast: "NBC"), channels)
        XCTAssertEqual(Set(nbcOnly.possibleBroadcasters.map(\.channel.id)), ["universo", "nbc"],
                       "NBC Universo contains NBC, but Universo alone needs a listed Universo broadcaster")
    }

    func testNetworkQualityVariantsBeatShortAffiliateNamesAndExpandedPoolIsBounded() {
        let affiliates = (0..<100).map { channel("affiliate\($0)", "NBC \($0) Local") }
        let national = [channel("4k", "NBC 4K"), channel("uhd", "NBC UHD"), channel("fhd", "NBC FHD"),
                        channel("1080", "NBC 1080p"), channel("hd", "NBC HD"), channel("base", "NBC")]
        let result = match(buccaneersAtBears(broadcast: "NBC"), affiliates + national)
        XCTAssertEqual(result.possibleBroadcasters.count, KyroSportsStreamMatcher.maximumBroadcasters)
        XCTAssertEqual(Array(result.possibleBroadcasters.prefix(6)).map(\.channel.id),
                       ["4k", "uhd", "fhd", "1080", "hd", "base"])
        XCTAssertTrue(result.possibleBroadcasters.allSatisfy { !$0.isAutoPlayEligible })
        XCTAssertEqual(result.possibleBroadcasters.map(\.channel.id),
                       match(buccaneersAtBears(broadcast: "NBC"), Array((affiliates + national).reversed()))
                           .possibleBroadcasters.map(\.channel.id))
    }

    func testSecondNationalBroadcastRetainsVerifiedEventAndThreeAttemptLimit() throws {
        let game = michiganStateAtMichigan(broadcast: "FOX")
        let guide = try guide([(id: "fox", title: "College Football: Michigan State at Michigan")])
        let events = (0..<5).map { channel("event\($0)", "Michigan State @ Michigan", category: "NCAAF") }
        // "FOX HD" would share the guide's "fox" channel by display name (quality tags are ignored),
        // so the unlinked broadcaster needs a name of its own.
        let result = match(game, events + [channel("fox4k", "FOX 4K", guideID: "fox"), channel("foxhd", "FOX Sports HD")], guide: guide)
        XCTAssertEqual(result.matches.count, 6)
        XCTAssertEqual(result.autoPlayCandidates.count, KyroSportsStreamMatcher.maximumAutoPlayCandidates)
        XCTAssertEqual(result.possibleBroadcasters.map(\.channel.id), ["foxhd"])
        XCTAssertFalse(try XCTUnwrap(result.possibleBroadcasters.first).isAutoPlayEligible)
    }

    func testFortyThousandChannelCatalogKeepsNetworkResultsBounded() throws {
        var channels = (0..<39_800).map { channel("other\($0)", "Station \($0)") }
        channels += (0..<200).map { channel("affiliate\($0)", "NBC \($0) Local") }
        // Keep the test at the production capacity, not one channel beyond it.
        channels[39_799] = channel("national4k", "NBC 4K")
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: channels))
        let result = KyroSportsStreamMatcher.match(request: .init(game: buccaneersAtBears(broadcast: "NBC"), now: now),
                                                   index: index, guide: nil, guideKeys: nil)
        XCTAssertEqual(result.diagnostics.catalogChannels, 40_000)
        XCTAssertEqual(result.possibleBroadcasters.count, KyroSportsStreamMatcher.maximumBroadcasters)
        XCTAssertEqual(result.possibleBroadcasters.first?.channel.id, "national4k")
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.autoPlayCandidates.isEmpty)
    }

    // MARK: Duplicates and shared guides

    func testDuplicateEventChannelsAreKeptInStableOrderAndAttemptsAreBounded() {
        let channels = (0..<6).map { channel("dup\($0)", "DAZN \($0): Michigan State @ Michigan", category: "DAZN EVENTS") }
        let first = match(michiganStateAtMichigan(), channels)
        let second = match(michiganStateAtMichigan(), channels.reversed())
        XCTAssertEqual(first.matches.map(\.channel.id), second.matches.map(\.channel.id))
        XCTAssertEqual(Set(first.matches.map(\.channel.id)).count, first.matches.count, "no channel twice")
        XCTAssertEqual(first.autoPlayCandidates.count, KyroSportsStreamMatcher.maximumAutoPlayCandidates)
    }

    func testSharedGuideIdentifierGivesEveryVariantAsAnAttempt() throws {
        let guide = try guide([(id: "cbssn", title: "College Football: Sam Houston at Jacksonville State")])
        let result = match(samHoustonAtJaxState(), [
            channel("hd", "CBS Sports Network HD", guideID: "cbssn"),
            channel("sd", "CBS Sports Network", guideID: "cbssn")
        ], guide: guide)
        XCTAssertEqual(result.confidence, .medium, "two variants still mean no single sure launch")
        XCTAssertEqual(Set(result.autoPlayCandidates.map(\.channel.id)), ["hd", "sd"])
    }

    func testStaleGuideProgrammeIsShownButNotAutoPlayed() throws {
        let stale = try guide([(id: "cbssn", title: "College Football: Sam Houston at Jacksonville State")],
                              fetchedAt: now.addingTimeInterval(-48 * 3600))
        let result = match(samHoustonAtJaxState(), [channel("hd", "CBS Sports Network HD", guideID: "cbssn")], guide: stale)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertTrue(result.autoPlayCandidates.isEmpty)
    }

    func testEventChannelContradictingItsGuideIsRejected() throws {
        let guide = try guide([(id: "ncaaf.05", title: "Sam Houston at Jacksonville State")])
        let result = match(samHoustonAtJaxState(), [
            channel("c", "NCAAF 05: Liberty @ Jacksonville State", guideID: "ncaaf.05")
        ], guide: guide)
        XCTAssertTrue(result.matches.isEmpty)
    }

    // MARK: SQLite guide

    func testSQLiteGuideWindowQueryFindsEventAndSkipsUnrelatedRows() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        func stamp(_ offset: TimeInterval) -> String { formatter.string(from: now.addingTimeInterval(offset)) }
        var xml = "<tv><channel id=\"cbssn\"><display-name>CBSSN</display-name></channel>"
        xml += "<programme channel=\"cbssn\" start=\"\(stamp(-600))\" stop=\"\(stamp(12_000))\"><title>College Football: Sam Houston at Jacksonville State</title></programme>"
        for index in 0..<200 {
            xml += "<channel id=\"other\(index)\"><display-name>Other \(index)</display-name></channel>"
            xml += "<programme channel=\"other\(index)\" start=\"\(stamp(-600))\" stop=\"\(stamp(3_000))\"><title>News \(index)</title></programme>"
        }
        xml += "</tv>"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("KyroSportsWindow-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: destination) }
        let built = try EPGSQLiteBuilder.build(xml: Data(xml.utf8), filter: nil, limits: EPGLimits(), fetchedAt: now,
                                                providerID: UUID(), fingerprint: Data(repeating: 0, count: EPGSourceFingerprint.length),
                                                destination: destination, readPolicy: .cachedOnly)
        let guide = EPGIndex(sqlite: built.index, statistics: built.statistics)
        let window = DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let rows = guide.windowPrograms(overlapping: window, anchors: ["houston", "jacksonville"])
        XCTAssertEqual(rows.map(\.key), ["cbssn"], "one bounded query, only anchored rows")

        let result = match(samHoustonAtJaxState(), [channel("hd", "CBSSN HD", guideID: "cbssn")], guide: guide)
        XCTAssertEqual(result.autoPlayCandidates.map(\.channel.id), ["hd"])
        XCTAssertLessThanOrEqual(result.diagnostics.guideRows, 1)
    }

    // MARK: Cancellation

    func testCancelledIndexBuildReportsCancellation() async {
        let channels = (0..<5_000).map { channel("c\($0)", "Channel \($0)") }
        let gate = AsyncStream<Void>.makeStream()
        let task = Task { () -> KyroSportsChannelIndex? in
            // Iteration ends as soon as the task is cancelled, so the build always sees it.
            for await _ in gate.stream { break }
            return KyroSportsChannelIndex.build(channels: channels)
        }
        task.cancel()
        gate.continuation.finish()
        let index = await task.value
        XCTAssertNil(index)
    }
}
