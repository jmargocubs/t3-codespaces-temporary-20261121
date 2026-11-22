import Foundation
import XCTest
@testable import Silo

/// Build 44 corrections: a repeated network broadcast cannot fill the initial list, accepted
/// matches beyond it stay discoverable, and short weak aliases cannot exhaust the guide budget.
/// Sunday Night Football, Tampa Bay Buccaneers at Chicago Bears, November 8, 2026.
final class KyroSportsStreamDiscoveryCorrectionsTests: XCTestCase {
    typealias Matcher = KyroSportsStreamMatcher

    private let kickoff = ISO8601DateFormatter().date(from: "2026-11-09T01:20:00Z")!
    private var now: Date { kickoff.addingTimeInterval(30 * 60) }

    // MARK: Fixtures

    private func buccaneersAtBears(broadcast: String = "NBC/Peacock") -> KyroSportsGame {
        let away = KyroSportsTeam(id: "espn.nfl.27", league: .nfl, abbreviation: "TB", nickname: "Buccaneers",
                                  location: "Tampa Bay", alternateNames: ["Tampa Bay Buccaneers", "Buccaneers"])
        let home = KyroSportsTeam(id: "espn.nfl.3", league: .nfl, abbreviation: "CHI", nickname: "Bears",
                                  location: "Chicago", alternateNames: ["Chicago Bears", "Bears"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .nfl, rawID: "401772900"), league: .nfl,
                              startTime: kickoff, status: .live, home: KyroGameTeam(team: home),
                              away: KyroGameTeam(team: away), broadcast: broadcast)
    }

    private func channel(_ id: String, _ name: String, _ category: String = "USA | NFL", guide: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: guide, name: name, streamURL: URL(string: "https://stream.invalid/live/user/pass/\(id).ts")!,
                      logoURL: URL(string: "https://logo.invalid/\(id).png"), category: category)
    }

    private func at(_ minutes: Double) -> Date { kickoff.addingTimeInterval(minutes * 60) }

    private func programme(_ guide: String, _ start: Double, _ end: Double, _ title: String,
                           subtitle: String? = nil, summary: String? = nil) -> EPGProgram {
        EPGProgram(channelID: guide, start: at(start), end: at(end), title: title, subtitle: subtitle, summary: summary)
    }

    private static let markets = ["New York WNBC", "Los Angeles KNBC", "Chicago WMAQ", "Philadelphia WCAU", "Dallas KXAS",
                                  "Boston WBTS", "Washington WRC", "Miami WTVJ", "San Diego KNSD", "Tampa WFLA",
                                  "Houston KPRC", "Denver KUSA", "Seattle KING", "Phoenix KPNX", "Atlanta WXIA",
                                  "Detroit WDIV", "Cleveland WKYC", "Hartford WVIT"]

    private static let eventNames = [
        "NFL 01: Tampa Bay Buccaneers vs Chicago Bears", "NFL 02 | Buccaneers @ Bears 11/08 8:20 PM ET",
        "USA NFL: Bucs vs Bears", "Sunday Night Football: Buccaneers vs Bears (NBC)",
        "NFL 07: Chicago Bears vs Tampa Bay Buccaneers - 1080p", "Peacock NFL: Buccaneers at Bears",
        "NFL 14 | TB Buccaneers vs CHI Bears", "NFL 15: Tampa Bay Buccaneers at Chicago Bears (ESP)",
        "PPV 16 - Buccaneers x Bears", "NFL 17: Buccaneers vs. Bears @ 8:20PM"
    ]

    private struct Scenario {
        var channels: [LiveTVChannel] = []
        var guideChannels: [EPGChannel] = []
        var programmes: [EPGProgram] = []
        var affiliateIDs: [String] = []
        var variantIDs: [String] = []
        var gamePassIDs: [String] = []
        var eventIDs: [String] = []
        var protectedIDs: [String] = []

        mutating func guide(_ id: String, name: String) {
            guideChannels.append(EPGChannel(id: id, displayNames: [name]))
        }
    }

    /// 18 NBC affiliates, national NBC quality/language/feed variants, Game Pass slots, event
    /// channels, and the channels the replay, date, pre-game and stale-name rules must keep out.
    private func sundayNight(noise: Int = 0, noiseKeyPrefix: String = "zz") -> Scenario {
        var s = Scenario()
        for index in 0..<noise {
            let key = "\(noiseKeyPrefix).\(String(format: "%05d", index))"
            s.channels.append(channel("noise\(index)", "Station \(index) HD", "UK | General", guide: key))
            s.guide(key, name: "Station \(index)")
            for slot in 0..<3 {
                let start = -150.0 + Double(slot) * 90
                s.programmes.append(programme(key, start, start + 90, "Kitchen Nightmares",
                                              summary: "Coverage while the children are watching."))
            }
        }
        for (index, market) in Self.markets.enumerated() {
            let key = "nbc.\(index)"
            s.channels.append(channel("aff\(String(format: "%02d", index))", "US: NBC \(market)", "USA | Locals NBC", guide: key))
            s.affiliateIDs.append("aff\(String(format: "%02d", index))")
            s.guide(key, name: "NBC \(market)")
            s.programmes.append(programme(key, -80, 0, "Football Night in America",
                                          summary: "Preview of Tampa Bay Buccaneers at Chicago Bears."))
            s.programmes.append(programme(key, 0, 200, "NBC Sunday Night Football",
                                          subtitle: "Tampa Bay Buccaneers at Chicago Bears"))
        }
        // National NBC feeds share one guide entry; listing quality, language and feed keep them apart.
        s.guide("nbc.national", name: "NBC National")
        s.programmes.append(programme("nbc.national", 0, 200, "NBC Sunday Night Football",
                                      subtitle: "Tampa Bay Buccaneers at Chicago Bears"))
        for (id, name, category) in [("v4k", "NBC 4K", "USA | Network"), ("vuhd", "NBC UHD", "USA | Network"),
                                     ("vfhd", "NBC FHD", "USA | Network"), ("ves", "ES | NBC", "ES | Deportes"),
                                     ("veast", "NBC East", "USA | Network")] {
            s.channels.append(channel(id, name, category, guide: "nbc.national"))
            s.variantIDs.append(id)
        }
        for index in 1...6 {
            let key = "gp.\(index)"
            let id = "gp\(String(format: "%02d", index))"
            s.channels.append(channel(id, "NFL Game Pass \(String(format: "%02d", index))", "USA | NFL Game Pass", guide: key))
            s.guide(key, name: "NFL Game Pass \(index)")
            s.programmes.append(programme(key, 0, 200, "Tampa Bay Buccaneers @ Chicago Bears"))
            s.gamePassIDs.append(id)
        }
        for (index, name) in Self.eventNames.enumerated() {
            let id = "ev\(String(format: "%02d", index))"
            s.channels.append(channel(id, name, "USA | NFL Sunday Ticket"))
            s.eventIDs.append(id)
        }
        // Protections: replay and pre-game names, another day's slot, a replay guide row, and a
        // Game Pass slot whose stale name contradicts its guide.
        s.channels += [channel("replay", "NFL 90: Buccaneers vs Bears [Replay]"),
                       channel("olddate", "NFL 91: Buccaneers @ Bears 11/01"),
                       channel("pregame", "NFL 92: Bears vs Buccaneers (Pre-Game)"),
                       channel("gpreplay", "NFL Game Pass 20", "USA | NFL Game Pass", guide: "gp.replay"),
                       channel("gpstale", "NFL Game Pass 21: Steelers vs Chargers", "USA | NFL Game Pass", guide: "gp.stale")]
        s.guide("gp.replay", name: "NFL Game Pass 20")
        s.programmes.append(programme("gp.replay", 0, 200, "Buccaneers at Bears (Replay)"))
        s.guide("gp.stale", name: "NFL Game Pass 21")
        s.programmes.append(programme("gp.stale", 0, 200, "Tampa Bay Buccaneers @ Chicago Bears"))
        s.protectedIDs = ["replay", "olddate", "pregame", "gpreplay", "gpstale"]
        // Network channels with no guide entry.
        s.channels += [channel("nbcbare", "NBC", "USA | Network"), channel("peacock", "Peacock Sports", "USA | Streaming")]
        return s
    }

    private func memoryGuide(_ s: Scenario) throws -> EPGIndex {
        try EPGIndex(document: EPGDocument(channels: s.guideChannels, programs: s.programmes),
                     fetchedAt: now.addingTimeInterval(-3600), now: now, limits: EPGLimits())
    }

    private var sqliteFiles: [URL] = []

    override func tearDown() {
        for url in sqliteFiles { try? FileManager.default.removeItem(at: url) }
        sqliteFiles = []
        super.tearDown()
    }

    private func sqliteGuide(_ s: Scenario) throws -> EPGIndex {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        var xml = "<tv>"
        for guide in s.guideChannels {
            xml += "<channel id=\"\(guide.id)\"><display-name>\(escape(guide.displayNames[0]))</display-name></channel>"
        }
        for p in s.programmes {
            xml += "<programme channel=\"\(p.channelID)\" start=\"\(formatter.string(from: p.start))\" stop=\"\(formatter.string(from: p.end))\">"
            xml += "<title>\(escape(p.title))</title>"
            if let subtitle = p.subtitle { xml += "<sub-title>\(escape(subtitle))</sub-title>" }
            if let summary = p.summary { xml += "<desc>\(escape(summary))</desc>" }
            xml += "</programme>"
        }
        xml += "</tv>"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("KyroDiscovery-\(UUID().uuidString).sqlite")
        sqliteFiles.append(destination)
        let built = try EPGSQLiteBuilder.build(xml: Data(xml.utf8), filter: nil, limits: EPGLimits(),
                                                fetchedAt: now.addingTimeInterval(-3600), providerID: UUID(),
                                                fingerprint: Data(repeating: 0, count: EPGSourceFingerprint.length),
                                                destination: destination, readPolicy: .cachedOnly)
        return EPGIndex(sqlite: built.index, statistics: built.statistics)
    }

    private func match(_ s: Scenario, guide: EPGIndex?, game: KyroSportsGame? = nil) throws -> KyroSportsStreamMatchResult {
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: s.channels))
        let keys = try guide.map { try XCTUnwrap(index.guideKeyMap(for: $0)) }
        return Matcher.match(request: .init(game: game ?? buccaneersAtBears(), now: now), index: index, guide: guide, guideKeys: keys)
    }

    /// The Build 44 reference: every accepted match by rank, and its automatic-playback choice.
    private func reference(_ result: KyroSportsStreamMatchResult) -> (ranked: [KyroSportsStreamMatch], autoPlay: [String]) {
        let ranked = (result.matches + result.overflowMatches).sorted(by: Matcher.rankedBefore)
        let autoPlay = ranked.prefix(Matcher.maximumMatches).filter(\.isAutoPlayEligible)
            .prefix(Matcher.maximumAutoPlayCandidates).map(\.channel.id)
        return (ranked, Array(autoPlay))
    }

    // MARK: Initial-list diversity

    func testSixteenPlusAffiliatesNoLongerFillTheInitialList() throws {
        let s = sundayNight()
        let result = try match(s, guide: memoryGuide(s))
        let context = Matcher.MatchContext(game: buccaneersAtBears())
        let affiliates = Set(s.affiliateIDs)
        XCTAssertEqual(result.matches.count, Matcher.maximumMatches, "the initial ten stays ten")
        let shownAffiliates = result.matches.filter { affiliates.contains($0.channel.id) }
        XCTAssertLessThanOrEqual(shownAffiliates.count, Matcher.maximumInitialPerBroadcast,
                                 "one repeated broadcast takes at most three initial rows")
        XCTAssertEqual(Set(shownAffiliates.compactMap { Matcher.broadcastGroup($0, context: context) }).count, 1,
                       "the affiliates are one broadcast group")
        XCTAssertGreaterThanOrEqual(result.matches.filter { $0.source == .channelName }.count, Matcher.reservedEventChannelSlots,
                                    "event channels are visible without expanding anything")
        XCTAssertTrue(result.matches.contains { s.variantIDs.contains($0.channel.id) },
                      "quality and language variants are not collapsed into the affiliates")
        let ranks = Dictionary(uniqueKeysWithValues: reference(result).ranked.enumerated().map { ($1.channel.id, $0) })
        XCTAssertEqual(result.matches.map { ranks[$0.channel.id]! }, result.matches.map { ranks[$0.channel.id]! }.sorted(),
                       "the initial list keeps score order")
    }

    func testEveryAcceptedMatchIsInitialOrOverflowAndNeverDowngraded() throws {
        let s = sundayNight()
        let result = try match(s, guide: memoryGuide(s))
        let expected = Set(s.affiliateIDs + s.variantIDs + s.gamePassIDs + s.eventIDs)
        let initial = Set(result.matches.map(\.channel.id))
        let overflow = Set(result.overflowMatches.map(\.channel.id))
        XCTAssertEqual(result.diagnostics.acceptedMatches, expected.count)
        XCTAssertEqual(initial.union(overflow), expected, "no accepted match disappears")
        XCTAssertTrue(initial.isDisjoint(with: overflow))
        XCTAssertEqual(result.overflowMatches.count, expected.count - Matcher.maximumMatches)
        XCTAssertEqual(result.omittedMatchCount, 0)
        XCTAssertTrue(result.overflowMatches.allSatisfy { $0.source == .guide || $0.source == .channelName },
                      "overflow keeps its event evidence")
        XCTAssertEqual(result.overflowMatches, result.overflowMatches.sorted(by: Matcher.rankedBefore))
        let broadcasters = Set(result.possibleBroadcasters.map(\.channel.id))
        XCTAssertTrue(broadcasters.isDisjoint(with: expected), "accepted matches are never listed as unconfirmed")
        XCTAssertTrue(broadcasters.contains("nbcbare"))
    }

    func testEventSpecificNFLChannelsAreAcceptedFromTheirNames() throws {
        let s = sundayNight()
        let result = try match(s, guide: nil)
        XCTAssertEqual(Set((result.matches + result.overflowMatches).map(\.channel.id)), Set(s.eventIDs),
                       "without a guide, only event-named channels match")
        XCTAssertTrue((result.matches + result.overflowMatches).allSatisfy { $0.source == .channelName })
        XCTAssertEqual(result.matches.count, Matcher.maximumMatches)
        XCTAssertFalse(result.autoPlayCandidates.isEmpty)
    }

    func testGamePassSlotsWithIdenticalGuideTitlesAreNotAssumedToBeOneStream() throws {
        var s = Scenario()
        for index in 0..<12 {
            let key = "gp.\(index)"
            s.channels.append(channel("gp\(String(format: "%02d", index))", "NFL Game Pass \(index)", "USA | NFL Game Pass", guide: key))
            s.guide(key, name: "NFL Game Pass \(index)")
            s.programmes.append(programme(key, 0, 200, "Tampa Bay Buccaneers @ Chicago Bears"))
        }
        let result = try match(s, guide: memoryGuide(s))
        let context = Matcher.MatchContext(game: buccaneersAtBears())
        XCTAssertTrue(result.matches.allSatisfy { Matcher.broadcastGroup($0, context: context) == nil })
        XCTAssertEqual(result.matches.map(\.channel.id), reference(result).ranked.prefix(Matcher.maximumMatches).map(\.channel.id),
                       "without a repeated network broadcast the initial list is the Build 44 top ten")
        XCTAssertEqual(result.overflowMatches.count, 2)
    }

    func testQualityLanguageAndFeedVariantsStayDistinct() throws {
        let s = sundayNight()
        let result = try match(s, guide: memoryGuide(s))
        let context = Matcher.MatchContext(game: buccaneersAtBears())
        let all = result.matches + result.overflowMatches
        let variantGroups = s.variantIDs.compactMap { id in all.first { $0.channel.id == id } }
            .compactMap { Matcher.broadcastGroup($0, context: context) }
        XCTAssertEqual(variantGroups.count, s.variantIDs.count)
        XCTAssertEqual(Set(variantGroups).count, s.variantIDs.count, "4K, UHD, FHD, Spanish and East are separate feeds")
        let affiliateGroup = all.first { $0.channel.id == s.affiliateIDs[0] }.flatMap { Matcher.broadcastGroup($0, context: context) }
        XCTAssertFalse(variantGroups.contains(affiliateGroup ?? ""))
        // The same affiliate programme at another time is another broadcast.
        let later = KyroSportsStreamMatch(id: "x", channel: channel("x", "US: NBC Boston WBTS", guide: "nbc.5"),
                                          program: programme("nbc.5", 30, 230, "NBC Sunday Night Football",
                                                             subtitle: "Tampa Bay Buccaneers at Chicago Bears"),
                                          confidence: .high, score: 1, reasons: [], isStale: false)
        XCTAssertNotEqual(Matcher.broadcastGroup(later, context: context), affiliateGroup)
    }

    func testFewerMatchesThanTheInitialListAreUnchanged() throws {
        var s = Scenario()
        for index in 0..<4 {
            let key = "nbc.\(index)"
            s.channels.append(channel("aff\(index)", "US: NBC \(Self.markets[index])", "USA | Locals NBC", guide: key))
            s.guide(key, name: "NBC \(index)")
            s.programmes.append(programme(key, 0, 200, "NBC Sunday Night Football", subtitle: "Tampa Bay Buccaneers at Chicago Bears"))
        }
        let result = try match(s, guide: memoryGuide(s))
        XCTAssertEqual(result.matches.map(\.channel.id), reference(result).ranked.map(\.channel.id))
        XCTAssertTrue(result.overflowMatches.isEmpty)
    }

    // MARK: Automatic playback

    func testAutoPlayCandidatesKeepTheBuild44Ranking() throws {
        let s = sundayNight()
        for guide in [try memoryGuide(s), try sqliteGuide(s)] {
            let result = try match(s, guide: guide)
            let expected = reference(result).autoPlay
            XCTAssertEqual(result.autoPlayCandidates.map(\.channel.id), expected)
            XCTAssertEqual(result.autoPlayCandidates.count, Matcher.maximumAutoPlayCandidates)
            XCTAssertTrue(Set(expected).isSubset(of: Set(result.matches.map(\.channel.id))),
                          "automatic candidates are always in the initial list")
            XCTAssertTrue(result.overflowMatches.allSatisfy { !expected.contains($0.channel.id) })
            XCTAssertEqual(result.confidence, .medium)
        }
    }

    // MARK: Protections

    func testReplayDateAndStaleNameProtectionsAreUnchanged() throws {
        let s = sundayNight()
        let result = try match(s, guide: memoryGuide(s))
        let listed = Set((result.matches + result.overflowMatches + result.possibleBroadcasters).map(\.channel.id))
        for id in s.protectedIDs { XCTAssertFalse(listed.contains(id), id) }
        let context = Matcher.MatchContext(game: buccaneersAtBears())
        func named(_ id: String) -> Matcher.Rejection? {
            guard case .rejected(let reason) = Matcher.assess(channelName: s.channels.first { $0.id == id }!,
                                                              context: context, stale: false) else { return nil }
            return reason
        }
        XCTAssertEqual(named("replay"), .nonEvent)
        XCTAssertEqual(named("pregame"), .nonEvent)
        XCTAssertEqual(named("olddate"), .nameDateConflicts)
        guard case .rejected(let stale) = Matcher.assess(
            program: programme("gp.stale", 0, 200, "Tampa Bay Buccaneers @ Chicago Bears"),
            channel: s.channels.first { $0.id == "gpstale" }!, context: context, stale: false, now: now) else {
            return XCTFail("a stale event name still vetoes its guide row")
        }
        XCTAssertEqual(stale, .channelContradictsGuide)
    }

    // MARK: Guide retrieval

    func testStrongAndWeakAnchorsForBuccaneersAtBears() {
        let context = Matcher.MatchContext(game: buccaneersAtBears())
        XCTAssertEqual(context.strongAnchors, ["bears", "buccaneers", "bucs"])
        XCTAssertEqual(context.weakAnchors, ["chi", "chicago", "tampa"])
        XCTAssertTrue(Set(context.anchors).isSubset(of: Set(context.strongAnchors + context.weakAnchors)),
                      "the two passes together cover every Build 44 anchor")
    }

    func testShortAbbreviationNoiseCannotExhaustTheBudgetSQLite() throws {
        // 1,000 guide channels whose keys sort before every event row, each with "chi" noise.
        let s = sundayNight(noise: 1_000, noiseKeyPrefix: "aa")
        let guide = try sqliteGuide(s)
        let result = try match(s, guide: guide)
        XCTAssertTrue(result.diagnostics.guideRowsTruncated, "3,000 noise rows exceed the 2,000-row budget")
        XCTAssertLessThanOrEqual(result.diagnostics.guideRows, Matcher.maximumGuideRows)
        XCTAssertGreaterThan(result.diagnostics.strongGuideRows, 0)
        let found = Set((result.matches + result.overflowMatches).map(\.channel.id))
        XCTAssertTrue(Set(s.affiliateIDs + s.variantIDs + s.gamePassIDs).isSubset(of: found),
                      "every guide-confirmed channel is read in the first pass")
    }

    func testShortAbbreviationNoiseCannotExhaustTheBudgetInMemory() throws {
        let s = sundayNight(noise: 1_000, noiseKeyPrefix: "aa")
        let result = try match(s, guide: memoryGuide(s))
        XCTAssertTrue(result.diagnostics.guideRowsTruncated)
        XCTAssertLessThanOrEqual(result.diagnostics.guideRows, Matcher.maximumGuideRows)
        let found = Set((result.matches + result.overflowMatches).map(\.channel.id))
        XCTAssertTrue(Set(s.affiliateIDs + s.variantIDs + s.gamePassIDs).isSubset(of: found))
    }

    func testWeakAliasRowsStillMatchWhenBudgetRemains() throws {
        var s = Scenario()
        s.channels = [channel("city", "NFL Game Pass 10", "USA | NFL Game Pass", guide: "gp.10")]
        s.guide("gp.10", name: "NFL Game Pass 10")
        s.programmes = [programme("gp.10", 0, 200, "Tampa Bay at Chicago")]
        let result = try match(s, guide: memoryGuide(s))
        XCTAssertEqual(result.matches.map(\.channel.id), ["city"], "city-only listings are read in the second pass")
        XCTAssertEqual(result.diagnostics.strongGuideRows, 0)
        XCTAssertEqual(result.diagnostics.weakGuideRows, 1)
        XCTAssertFalse(result.diagnostics.guideRowsTruncated)
    }

    func testWindowRowsAreDeterministicAndReportTruncation() throws {
        var s = Scenario()
        // Keys inserted in reverse order; distances from the middle of the window differ.
        for index in (0..<30).reversed() {
            let key = "k.\(String(format: "%02d", index))"
            s.guide(key, name: key)
            s.programmes.append(programme(key, Double(index % 5) * 10, 200, "Buccaneers at Bears"))
        }
        let window = DateInterval(start: at(-120), end: at(120))
        for guide in [try memoryGuide(s), try sqliteGuide(s)] {
            let all = guide.windowRows(overlapping: window, anchors: ["bears"], limit: 30)
            XCTAssertFalse(all.truncated, "exactly the budget is not truncation")
            XCTAssertEqual(all.rows.count, 30)
            let capped = guide.windowRows(overlapping: window, anchors: ["bears"], limit: 12)
            XCTAssertTrue(capped.truncated)
            XCTAssertEqual(capped.rows.map(\.key), Array(all.rows.prefix(12)).map(\.key), "the nearest rows win")
            XCTAssertEqual(capped.rows.map(\.key), (0..<30).filter { $0 % 5 == 0 }.map { "k.\(String(format: "%02d", $0))" }
                           + (0..<30).filter { $0 % 5 == 1 }.prefix(6).map { "k.\(String(format: "%02d", $0))" },
                           "distance, then guide key")
            let excluded = guide.windowRows(overlapping: window, anchors: ["bears"], excluding: ["buccaneers"], limit: 30)
            XCTAssertTrue(excluded.rows.isEmpty, "rows a first pass read are not read again")
        }
        let memory = try memoryGuide(s).windowRows(overlapping: window, anchors: ["bears"], limit: 12)
        let sqlite = try sqliteGuide(s).windowRows(overlapping: window, anchors: ["bears"], limit: 12)
        XCTAssertEqual(memory.rows.map(\.key), sqlite.rows.map(\.key), "SQLite and in-memory guides agree")
    }

    func testSQLiteExclusionKeepsRowsWithoutSubtitleOrSummary() throws {
        var s = Scenario()
        s.guide("a", name: "A")
        s.programmes = [programme("a", 0, 200, "Tampa Bay at Chicago")]
        let rows = try sqliteGuide(s).windowRows(overlapping: DateInterval(start: at(-120), end: at(120)),
                                                 anchors: ["tampa"], excluding: ["bears"], limit: 10)
        XCTAssertEqual(rows.rows.map(\.key), ["a"], "a NULL subtitle must not drop the row")
    }

    func testCancelledWindowReadReportsCancellation() async throws {
        let s = sundayNight(noise: 600)
        let guide = try memoryGuide(s)
        let window = DateInterval(start: at(-120), end: at(120))
        let read = await Task.detached { () -> EPGWindowRows in
            withUnsafeCurrentTask { $0?.cancel() }
            return guide.windowRows(overlapping: window, anchors: ["chi"], limit: 2_000)
        }.value
        XCTAssertTrue(read.cancelled)
        XCTAssertTrue(read.rows.isEmpty)
    }

    // MARK: Overflow presentation

    func testOverflowIsAnExpandableSectionKeptApartFromUnconfirmedChannels() throws {
        let s = sundayNight()
        let result = try match(s, guide: memoryGuide(s))
        let sections = KyroSportsStreamSection.make(matches: result.matches, overflow: result.overflowMatches,
                                                    broadcasters: result.possibleBroadcasters,
                                                    status: { _ in .untested }, currentChannelID: nil)
        XCTAssertEqual(sections.map(\.kind), [.eventMatches, .moreMatches, .networkChannels])
        let more = try XCTUnwrap(sections.first { $0.kind == .moreMatches })
        XCTAssertFalse(more.startsExpanded)
        XCTAssertEqual(more.rows.count, result.overflowMatches.count)
        XCTAssertTrue(more.rows.allSatisfy { $0.status == .eventMatch || $0.status == .possibleMatch })
        XCTAssertFalse(more.rows.contains { $0.status == .unconfirmed })
        let ids = sections.flatMap(\.rows).map(\.channelID)
        XCTAssertEqual(ids.count, Set(ids).count, "each channel appears once")

        let tried = KyroSportsStreamSection.make(matches: result.matches, overflow: result.overflowMatches,
                                                 broadcasters: [], status: { $0 == result.overflowMatches[0].channel.id ? .failed : .untested },
                                                 currentChannelID: nil)
        XCTAssertTrue(try XCTUnwrap(tried.first { $0.kind == .moreMatches }).startsExpanded, "a tried stream stays visible")
    }

    func testOverflowRowsAreBoundedAndDeduplicated() {
        let matches = (0..<3).map { KyroSportsStreamMatch(id: "m\($0)", channel: channel("m\($0)", "M\($0)"), program: nil,
                                                          confidence: .medium, score: 50, reasons: [], isStale: false,
                                                          source: .channelName) }
        let overflow = (0..<80).map { KyroSportsStreamMatch(id: "o\($0)", channel: channel("o\($0)", "O\($0)"), program: nil,
                                                            confidence: .medium, score: 40, reasons: [], isStale: false,
                                                            source: .channelName) }
        let sections = KyroSportsStreamSection.make(matches: matches, overflow: [matches[0]] + overflow, broadcasters: [],
                                                    status: { _ in .untested }, currentChannelID: nil)
        let more = sections.first { $0.kind == .moreMatches }
        XCTAssertEqual(more?.rows.count, Matcher.maximumOverflowMatches - 1, "the duplicate is dropped, the list is bounded")
    }

    @MainActor
    func testPlaybackContextResolvesOverflowWithoutDuplicates() throws {
        let s = sundayNight()
        let result = try match(s, guide: memoryGuide(s))
        var context = KyroSportsPlaybackContext(game: buccaneersAtBears(), alternatives: result.matches,
                                                overflow: result.overflowMatches, broadcasters: result.possibleBroadcasters)
        let pick = result.overflowMatches[0]
        XCTAssertEqual(context.match(for: pick.channel.id)?.id, pick.id)
        context.include(pick)
        XCTAssertEqual(context.alternatives.count, result.matches.count, "an overflow pick is not appended twice")
        XCTAssertEqual(context.overflow.count, result.overflowMatches.count)
    }

    // MARK: Capacity

    func testFortyThousandChannelCatalogWithNoisyGuide() throws {
        var s = sundayNight(noise: 6_000, noiseKeyPrefix: "aa")
        let filler = 40_000 - s.channels.count
        s.channels += (0..<filler).map { channel("filler\($0)", "Channel \($0) HD", "World | General") }
        XCTAssertEqual(s.channels.count, 40_000)
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: s.channels))
        let request = KyroSportsStreamMatchRequest(game: buccaneersAtBears(), now: now)
        let expected = Set(s.affiliateIDs + s.variantIDs + s.gamePassIDs + s.eventIDs)
        for (label, guide) in [("memory", try memoryGuide(s)), ("sqlite", try sqliteGuide(s))] {
            let keys = try XCTUnwrap(index.guideKeyMap(for: guide))
            var durations: [Double] = []
            var result: KyroSportsStreamMatchResult!
            for _ in 0..<3 {
                let started = DispatchTime.now().uptimeNanoseconds
                result = Matcher.match(request: request, index: index, guide: guide, guideKeys: keys)
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            print("discovery_40k guide=\(label) match_ms=\(durations.map { String(format: "%.1f", $0) }.joined(separator: ",")) "
                  + "guide_rows=\(result.diagnostics.guideRows) strong=\(result.diagnostics.strongGuideRows) "
                  + "weak=\(result.diagnostics.weakGuideRows) truncated=\(result.diagnostics.guideRowsTruncated) "
                  + "accepted=\(result.diagnostics.acceptedMatches) initial=\(result.matches.count) "
                  + "overflow=\(result.overflowMatches.count) broadcasters=\(result.possibleBroadcasters.count)")
            XCTAssertEqual(Set((result.matches + result.overflowMatches).map(\.channel.id)), expected, label)
            XCTAssertEqual(result.matches.count, Matcher.maximumMatches)
            XCTAssertLessThanOrEqual(result.overflowMatches.count, Matcher.maximumOverflowMatches)
            XCTAssertLessThanOrEqual(result.possibleBroadcasters.count, Matcher.maximumBroadcasters)
            XCTAssertLessThanOrEqual(result.diagnostics.guideRows, Matcher.maximumGuideRows)
            XCTAssertTrue(result.diagnostics.guideRowsTruncated, label)
            XCTAssertLessThan(result.diagnostics.nameCandidates, 2_000, "a tap evaluates candidates, not the catalog")
            XCTAssertLessThan(durations.min()!, 5_000, "\(label) match stays interactive even in an unoptimized build")
        }
    }
}
