import Foundation
import XCTest
@testable import Silo

/// `LiveTVService` advances a provider's guide generation for every guide index it installs,
/// replaces or removes, and leaves other providers alone.
@MainActor
final class LiveTVGuideGenerationTests: XCTestCase {
    private let providerA = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let providerB = UUID(uuidString: "B1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!

    func testInstallReplaceAndRemoveEachAdvanceOnlyThatProvider() {
        let service = makeService()
        XCTAssertEqual(service.guideGeneration(for: providerA), 0)

        service.installGuideForResidencyTesting(.empty(fetchedAt: .now), providerID: providerA, channels: [])
        let installed = service.guideGeneration(for: providerA)
        XCTAssertGreaterThan(installed, 0)

        // Same contents still count: the service cannot tell a short-guide overlay from a no-op.
        service.installGuideForResidencyTesting(.empty(fetchedAt: .now), providerID: providerA, channels: [])
        let replaced = service.guideGeneration(for: providerA)
        XCTAssertGreaterThan(replaced, installed)

        service.installGuideForResidencyTesting(.empty(fetchedAt: .now), providerID: providerB, channels: [],
                                                selectProvider: false)
        XCTAssertEqual(service.guideGeneration(for: providerA), replaced)

        service.forgetProvider(providerA)
        XCTAssertGreaterThan(service.guideGeneration(for: providerA), replaced)
        let removed = service.guideGeneration(for: providerA)

        // Clearing a provider that no longer has a guide is not a change.
        service.forgetProvider(providerA)
        XCTAssertEqual(service.guideGeneration(for: providerA), removed)
        service.forgetProvider(providerB)
    }

    private func makeService() -> LiveTVService {
        let defaults = UserDefaults(suiteName: "LiveTVGuideGenerationTests.\(UUID().uuidString)")!
        return LiveTVService(defaults: defaults, secretStore: GenerationSecretStore(),
                             epg: EPGService(cache: nil, loader: URLSessionEPGFeedLoader.makeDefault(),
                                             fingerprinter: .inMemory()))
    }
}

@MainActor
private final class GenerationSecretStore: LiveTVSecretStore {
    func read(account: String) -> String? { nil }
    func save(_ value: String, account: String) -> Bool { true }
    func remove(account: String) -> Bool { true }
}
