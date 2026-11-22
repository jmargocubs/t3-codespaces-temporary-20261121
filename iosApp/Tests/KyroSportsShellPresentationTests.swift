import Foundation
import XCTest
@testable import Silo

/// Build 38: Sports Hub plays over itself on the shell presenter. Before, a Picture in Picture
/// hand-off for a shell player fell back to the list presenter and asked for a Live TV screen,
/// which selected the Live TV tab behind the player.
@MainActor
final class KyroSportsShellPresentationTests: XCTestCase {
    private var presentation: LiveTVPresentation!
    private var navigations = 0
    private var stops = 0
    private var pictureInPictureStops = 0

    override func setUp() async throws {
        presentation = LiveTVPresentation(scheduler: KyroSportsPlaybackTestScheduler())
        navigations = 0
        stops = 0
        pictureInPictureStops = 0
        presentation.navigateToLiveTV = { [unowned self] in navigations += 1 }
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = { [unowned self] in pictureInPictureStops += 1 }
    }

    private func channel(_ name: String, hls: Bool = false) -> LiveTVChannel {
        LiveTVChannel(id: name, guideID: name, name: name,
                      streamURL: URL(string: "https://tv.example/\(name).\(hls ? "m3u8" : "ts")")!,
                      logoURL: nil, category: "Sports")
    }

    func testSportsHubOpensThePlayerDirectlyOverItself() {
        let game = channel("dazn")
        XCTAssertEqual(presentation.select(game, from: .shell), .present)
        XCTAssertEqual(presentation.phase, .presented(game, .shell))
        XCTAssertEqual(presentation.channel(for: .shell), game)
        XCTAssertNil(presentation.channel(for: .list), "no Live TV screen shows a second cover")
        XCTAssertEqual(navigations, 0, "no Live TV tab is selected")
    }

    func testClosingThePlayerReturnsToSportsHub() {
        let game = channel("dazn")
        _ = presentation.select(game, from: .shell)
        presentation.coverDismissed(from: .shell)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(navigations, 0)
    }

    func testPictureInPictureRestoreComesBackOverTheShell() {
        let game = channel("dazn")
        _ = presentation.select(game, from: .shell)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.phase, .pictureInPicture(game))

        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(navigations, 0, "the Live TV tab is not selected to restore a Sports player")
        XCTAssertEqual(presentation.phase, .restoring(game, .shell))
        presentation.playerDidAppear(game)
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(presentation.phase, .presented(game, .shell))
    }

    func testSwitchingStreamsDuringPictureInPictureStaysOnTheShell() {
        let first = channel("dazn")
        let second = channel("ncaaf", hls: true)
        _ = presentation.select(first, from: .shell)
        presentation.pictureInPictureStartedFromControl()
        // Crossing route classes closes the window deliberately and shows the player instead.
        XCTAssertEqual(presentation.select(second, from: .shell), .exitingPictureInPicture)
        XCTAssertEqual(pictureInPictureStops, 1)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.phase, .presented(second, .shell))
        XCTAssertEqual(navigations, 0)
    }

    func testClosingPictureInPictureEndsPlaybackWithoutNavigating() {
        let game = channel("dazn")
        _ = presentation.select(game, from: .shell)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(navigations, 0)
    }

    /// Ordinary Live TV keeps its behavior: a list player restored with no Live TV screen up
    /// still asks for one.
    func testOrdinaryLiveTVRestoreStillBringsLiveTVForward() {
        let news = channel("news")
        presentation.surfaceAppeared(.list)
        _ = presentation.select(news, from: .list)
        presentation.pictureInPictureStartedFromControl()
        presentation.surfaceDisappeared(.list)
        presentation.restoreRequested { _ in }
        XCTAssertEqual(navigations, 1)
        XCTAssertEqual(presentation.phase, .restoring(news, nil))
    }

    func testOrdinaryLiveTVListPlayerIsUnchanged() {
        let news = channel("news")
        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        XCTAssertEqual(presentation.channel(for: .list), news)
        XCTAssertNil(presentation.channel(for: .shell))
        presentation.coverDismissed(from: .list)
        XCTAssertEqual(presentation.phase, .idle)
    }
}
