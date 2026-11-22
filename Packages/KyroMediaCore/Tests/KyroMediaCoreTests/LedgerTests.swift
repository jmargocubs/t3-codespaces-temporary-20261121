import Foundation
import XCTest
import KyroFoundation
import KyroLedger

@MainActor final class LedgerTests: XCTestCase {
    func testOneThousandMergePermutationsAndAlgebra() throws {
        let profile = KyroProfileID()
        let operations: [LedgerOperation] = (0..<30).map { (n: Int) -> LedgerOperation in
            let clock = HybridLogicalClock(physicalMilliseconds: Int64(n / 3), logical: UInt32(n % 3), node: "a")
            return LedgerOperation(profileID: profile, media: "movie-\(n % 4)", value: .favorite(n % 2 == 0), clock: clock)
        }
        let expected = LedgerState(operations: Set(operations))
        var random = SeededRandom(state: 53)
        for _ in 0..<1_000 {
            let shuffled = operations.shuffled(using: &random)
            let a = LedgerState(operations: Set(shuffled.prefix(10)))
            let b = LedgerState(operations: Set(shuffled.dropFirst(10).prefix(10)))
            let c = LedgerState(operations: Set(shuffled.suffix(10)))
            XCTAssertEqual(a.merged(with: b), b.merged(with: a))
            XCTAssertEqual(a.merged(with: a), a)
            XCTAssertEqual(a.merged(with: b).merged(with: c), a.merged(with: b.merged(with: c)))
            let result = shuffled.reduce(LedgerState()) { $0.merged(with: LedgerState(operations: [$1])) }
            XCTAssertEqual(result, expected)
            XCTAssertEqual(result.favorites(profile: profile), expected.favorites(profile: profile))
        }
    }
    func testObservedRemoveRetainsConcurrentAdd() {
        let profile = KyroProfileID(), clock = HybridLogicalClock(physicalMilliseconds: 1, logical: 0, node: "a")
        let add = LedgerOperation(profileID: profile, media: "film", value: .collectionAdd(collection: "weekend"), clock: clock)
        let remove = LedgerOperation(profileID: profile, media: "film", value: .collectionRemove(collection: "weekend", observed: [add.id]), clock: clock)
        let concurrent = LedgerOperation(profileID: profile, media: "film", value: .collectionAdd(collection: "weekend"), clock: clock)
        let removed = LedgerState(operations: [remove]).merged(with: LedgerState(operations: [add]))
        XCTAssertTrue(removed.collection(profile: profile, name: "weekend").isEmpty)
        XCTAssertEqual(removed.merged(with: LedgerState(operations: [concurrent])).collection(profile: profile, name: "weekend"), ["film"])
    }
    func testContinueWatchingAndProfilePersistence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.sqlite")
        let profile = KyroProfileID(), other = KyroProfileID()
        let db = try SQLiteDatabase(path: url)
        let store = LedgerStore(database: db, profile: profile)
        func op(_ media: String, _ value: LedgerValue, _ time: Int64) -> LedgerOperation {
            LedgerOperation(profileID: profile, media: media, value: value, clock: HybridLogicalClock(physicalMilliseconds: time, logical: 0, node: "test"))
        }
        let operations: Set<LedgerOperation> = [
            op("active", .progress(try PlaybackProgress(position: 40, duration: 100)), 1),
            op("completed", .progress(try PlaybackProgress(position: 96, duration: 100)), 2),
            op("watched", .progress(try PlaybackProgress(position: 20, duration: 100)), 3),
            op("watched", .watched(true), 4), op("active", .watchlist(true), 5),
            op("", .preference(name: "language", value: "en"), 6)
        ]
        try await store.merge(LedgerState(operations: operations), nowMilliseconds: 100)
        try await db.close()
        let reopened = try SQLiteDatabase(path: url)
        let state = try await LedgerStore(database: reopened, profile: profile).state()
        XCTAssertEqual(state.operations, operations)
        XCTAssertEqual(state.continueWatching(profile: profile).map(\.media), ["active"])
        XCTAssertEqual(state.watchlist(profile: profile), ["active"])
        XCTAssertTrue(state.continueWatching(profile: other).isEmpty)
        let isolated = try await LedgerStore(database: reopened, profile: other).state()
        XCTAssertTrue(isolated.operations.isEmpty)
        do { try await LedgerStore(database: reopened, profile: other).merge(state, nowMilliseconds: 100); XCTFail("Cross-profile import") } catch {}
        try await reopened.close()
        XCTAssertThrowsError(try PlaybackProgress(position: .nan, duration: 100))
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
