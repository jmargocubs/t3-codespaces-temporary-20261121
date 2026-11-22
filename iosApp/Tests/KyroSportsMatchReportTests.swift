#if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
import Foundation
import XCTest
@testable import Silo

/// INTERNAL TEST builds only: the Sports Match Report is bounded, explains every outcome and
/// never carries stream or provider addresses, credentials or raw channel IDs.
final class KyroSportsMatchReportTests: XCTestCase {
    private let kickoff = ISO8601DateFormatter().date(from: "2026-11-09T01:20:00Z")!
    private var now: Date { kickoff.addingTimeInterval(30 * 60) }
    private let providerID = UUID()

    private func game() -> KyroSportsGame {
        let away = KyroSportsTeam(id: "espn.nfl.27", league: .nfl, abbreviation: "TB", nickname: "Buccaneers",
                                  location: "Tampa Bay", alternateNames: ["Tampa Bay Buccaneers"])
        let home = KyroSportsTeam(id: "espn.nfl.3", league: .nfl, abbreviation: "CHI", nickname: "Bears",
                                  location: "Chicago", alternateNames: ["Chicago Bears"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .nfl, rawID: "401772900"), league: .nfl,
                              startTime: kickoff, status: .live, home: KyroGameTeam(team: home),
                              away: KyroGameTeam(team: away), broadcast: "NBC/Peacock")
    }

    /// IDs shaped like production ("<provider UUID>:<sha256 hex>"); stream URLs carry credentials.
    private func channel(_ tag: String, _ name: String, _ category: String = "USA | NFL", guide: String? = nil) -> LiveTVChannel {
        let digest = String(repeating: tag.unicodeScalars.map { String(format: "%02x", $0.value) }.joined(), count: 32).prefix(64)
        return LiveTVChannel(id: "\(providerID.uuidString):\(digest)", guideID: guide, name: name,
                             streamURL: URL(string: "http://secret-host.example:8080/live/alice/hunter2/\(tag).ts?token=abc123")!,
                             logoURL: URL(string: "https://logos.secret-host.example/\(tag).png"), category: category)
    }

    private func input(channels: [LiveTVChannel], programmes: [EPGProgram]) throws -> KyroSportsMatchReportBuilder.Input {
        let guideChannels = Set(programmes.map(\.channelID)).map { EPGChannel(id: $0, displayNames: [$0]) }
        let guide = try EPGIndex(document: EPGDocument(channels: guideChannels, programs: programmes),
                                 fetchedAt: now.addingTimeInterval(-3600), now: now, limits: EPGLimits())
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: channels, providerID: providerID, catalogRevision: 7))
        return .init(request: .init(game: game(), now: now), index: index, guide: guide,
                     guideKeys: index.guideKeyMap(for: guide), guideGeneration: 3, storageMode: .memory, createdAt: now)
    }

    private func snf(_ guide: String) -> EPGProgram {
        EPGProgram(channelID: guide, start: kickoff, end: kickoff.addingTimeInterval(12_000),
                   title: "NBC Sunday Night Football", subtitle: "Tampa Bay Buccaneers at Chicago Bears")
    }

    private func sampleReport() throws -> (KyroSportsMatchReport, [LiveTVChannel]) {
        var channels = (0..<16).map { channel("a\($0)", "US: NBC Market \($0)", "USA | Locals NBC", guide: "nbc.\($0)") }
        var programmes = (0..<16).map { snf("nbc.\($0)") }
        channels += (0..<6).map { channel("e\($0)", "NFL 0\($0): Buccaneers vs Bears", "USA | NFL Sunday Ticket") }
        channels += [channel("r", "NFL 90: Buccaneers vs Bears [Replay]"),
                     channel("s", "NFL Game Pass 21: Steelers vs Chargers", "USA | NFL Game Pass", guide: "gp.stale"),
                     channel("f", "Chicago Bears Fan Channel"),
                     channel("u", "Bears Country Radio http://bad.example/feed?user=alice", "Audio"),
                     channel("n", "NBC HD", "USA | Network")]
        programmes.append(EPGProgram(channelID: "gp.stale", start: kickoff, end: kickoff.addingTimeInterval(12_000),
                                     title: "Tampa Bay Buccaneers @ Chicago Bears"))
        let report = try XCTUnwrap(KyroSportsMatchReportBuilder.build(try input(channels: channels, programmes: programmes)))
        return (report, channels)
    }

    func testReportExplainsInitialOverflowAndRejections() throws {
        let (report, channels) = try sampleReport()
        XCTAssertEqual(report.catalog, .init(revision: 7, playableChannels: channels.count))
        XCTAssertEqual(report.guide.generation, 3)
        XCTAssertEqual(report.guide.storageMode, "memory")
        XCTAssertEqual(report.guide.strongAnchors, ["bears", "buccaneers", "bucs"])
        XCTAssertEqual(report.guide.rowBudget, KyroSportsStreamMatcher.maximumGuideRows)
        XCTAssertFalse(report.guide.truncated)
        XCTAssertEqual(report.summary.accepted, 22)
        XCTAssertEqual(report.summary.initial, KyroSportsStreamMatcher.maximumMatches)
        XCTAssertEqual(report.summary.overflow, 12)
        XCTAssertEqual(report.summary.autoPlayCandidates, KyroSportsStreamMatcher.maximumAutoPlayCandidates)

        let byName = Dictionary(report.candidates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(report.candidates.filter { $0.outcome == .initial }.count, 10)
        XCTAssertEqual(report.candidates.filter { $0.outcome == .overflow }.count, 12)
        XCTAssertEqual(report.candidates.filter(\.autoPlayCandidate).count, 3)
        XCTAssertEqual(report.candidates.filter { $0.outcome != .rejected }.map { $0.rank! }, Array(1...22), "ranked in order")
        XCTAssertEqual(byName["NFL 90: Buccaneers vs Bears [Replay]"]?.rejection, .nonEvent)
        XCTAssertEqual(byName["NFL Game Pass 21: Steelers vs Chargers"]?.rejection, .channelContradictsGuide)
        XCTAssertEqual(byName["Chicago Bears Fan Channel"]?.rejection, .oneParticipantNotEnough)
        XCTAssertNil(byName["NBC HD"], "a broadcaster lead is not an evaluated candidate")

        let bears = try XCTUnwrap(report.universalSearch.first { $0.query == "Bears" })
        XCTAssertEqual(bears.hits, 6 + 3, "event channels, plus the replay, fan and radio channels")
        XCTAssertEqual(bears.notAccepted, 3)
        XCTAssertTrue(bears.examples.contains { $0.outcome == .rejected && $0.rejection == .nonEvent })
    }

    func testReportCarriesNoAddressesCredentialsOrRawIDs() throws {
        let (report, channels) = try sampleReport()
        let json = try XCTUnwrap(String(data: try report.jsonData(), encoding: .utf8))
        for secret in ["://", "http", "secret-host", "alice", "hunter2", "token", "abc123", "8080", ".png", ".ts",
                       providerID.uuidString, providerID.uuidString.lowercased()] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(secret), secret)
        }
        for channel in channels {
            XCTAssertFalse(json.contains(String(channel.id.split(separator: ":").last!)), "raw channel IDs never appear")
        }
        XCTAssertTrue(report.candidates.allSatisfy { $0.ref.count == 12 && $0.ref.allSatisfy(\.isHexDigit) })
        XCTAssertEqual(KyroSportsMatchReport.reference(forChannelID: channels[0].id),
                       KyroSportsMatchReport.reference(forChannelID: channels[0].id), "stable references")
        XCTAssertEqual(KyroSportsMatchReport.label("Feed https://x.example/a?b=c www.y.example user=bob"),
                       "Feed [removed] [removed] [removed]")
    }

    func testReportIsBounded() throws {
        var channels = (0..<300).map { channel("x\($0)", "NFL \($0): Buccaneers vs Bears \(String(repeating: "Extra ", count: 40))") }
        channels += (0..<300).map { channel("y\($0)", "Bears Talk \($0)") }
        let report = try XCTUnwrap(KyroSportsMatchReportBuilder.build(try input(channels: channels, programmes: [])))
        XCTAssertEqual(report.candidates.count, KyroSportsMatchReport.maximumCandidates)
        XCTAssertEqual(report.candidates.count + report.candidatesOmitted, 600)
        XCTAssertTrue(report.candidates.allSatisfy { $0.name.count <= KyroSportsMatchReport.maximumLabelLength })
        XCTAssertTrue(report.universalSearch.allSatisfy { $0.examples.count <= KyroSportsMatchReport.maximumSearchExamplesPerQuery })
        XCTAssertLessThanOrEqual(try report.jsonData().count, KyroSportsMatchReport.maximumBytes)
        XCTAssertEqual(report.summary.omitted, 300 - KyroSportsStreamMatcher.maximumMatches - KyroSportsStreamMatcher.maximumOverflowMatches)
        XCTAssertEqual(report.guide.storageMode, "memory")
    }

    func testCancelledBuildReturnsNil() async throws {
        let input = try input(channels: (0..<2_000).map { channel("c\($0)", "NFL \($0): Buccaneers vs Bears") }, programmes: [])
        let report = await Task.detached { () -> KyroSportsMatchReport? in
            withUnsafeCurrentTask { $0?.cancel() }
            return KyroSportsMatchReportBuilder.build(input)
        }.value
        XCTAssertNil(report)
    }
}
#endif
