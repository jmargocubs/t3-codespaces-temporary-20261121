#if os(iOS)
import Foundation
import XCTest
@testable import Silo

/// The introduction appears once, only to a new iPhone install, and never
/// stands in front of an existing user's session.
final class KyroIntroductionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "KyroIntroductionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func resolve(
        _ state: AppRouter.AuthState,
        hasSavedServers: Bool = false,
        isEligibleDevice: Bool = true
    ) -> Bool {
        KyroIntroduction.resolveAtLaunch(
            initialState: state,
            hasSavedServers: hasSavedServers,
            isEligibleDevice: isEligibleDevice,
            defaults: defaults
        )
    }

    func testNewInstallSeesIntroductionUntilItIsCompleted() {
        XCTAssertTrue(resolve(.needsServerSetup))
        // Quitting mid-introduction shows it again next launch.
        XCTAssertTrue(resolve(.needsServerSetup))

        KyroIntroduction.markCompleted(defaults: defaults)
        XCTAssertFalse(resolve(.needsServerSetup))
    }

    func testStandaloneFirstLaunchCanIntroduceBeforeLocalProfilePicker() {
        XCTAssertTrue(resolve(.needsProfile))
        XCTAssertTrue(resolve(.needsProfile))
        KyroIntroduction.markCompleted(defaults: defaults)
        XCTAssertFalse(resolve(.needsProfile))
    }

    func testExistingUsersBypassAndStayBypassed() {
        for state in [AppRouter.AuthState.authenticated, .needsProfile, .needsLogin] {
            XCTAssertFalse(resolve(state, hasSavedServers: true), "\(state)")
        }
        // Removing every server later does not turn them into a new user.
        XCTAssertFalse(resolve(.needsServerSetup))
    }

    func testSavedServerWithoutSessionIsNotNew() {
        XCTAssertFalse(resolve(.needsServerSetup, hasSavedServers: true))
        XCTAssertFalse(resolve(.needsServerSetup))
    }

    func testIneligibleDeviceNeitherShowsNorConsumesTheIntroduction() {
        XCTAssertFalse(resolve(.needsServerSetup, isEligibleDevice: false))
        XCTAssertFalse(defaults.bool(forKey: KyroIntroduction.completedDefaultsKey))
    }
}
#endif
