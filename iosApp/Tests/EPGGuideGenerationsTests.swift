import Foundation
import XCTest
@testable import Silo

final class EPGGuideGenerationsTests: XCTestCase {
    private let providerA = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let providerB = UUID(uuidString: "B1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!

    func testUnpublishedProviderStartsAtZero() {
        XCTAssertEqual(EPGGuideGenerations().generation(for: providerA), 0)
    }

    func testEveryChangeAdvancesOnlyThatProvider() {
        var generations = EPGGuideGenerations()
        let first = generations.advance(providerA)
        XCTAssertEqual(generations.generation(for: providerA), first)
        XCTAssertEqual(generations.generation(for: providerB), 0)

        let second = generations.advance(providerA)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(generations.generation(for: providerA), second)
        XCTAssertEqual(generations.generation(for: providerB), 0)
    }

    func testProvidersNeverShareAGeneration() {
        var generations = EPGGuideGenerations()
        let a = generations.advance(providerA)
        let b = generations.advance(providerB)
        let aAgain = generations.advance(providerA)
        XCTAssertEqual(Set([a, b, aAgain]).count, 3)
        XCTAssertEqual(generations.generation(for: providerB), b, "A's change leaves B's search index valid")
    }
}
