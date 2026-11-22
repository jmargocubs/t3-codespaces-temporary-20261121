import Foundation
import Synchronization
import XCTest
import KyroFoundation
import KyroCatalog
import KyroSources
import KyroSourceJellyfin
import KyroSourceXtream

actor SyntheticHTTP: HTTPClient {
    var responses: [HTTPResponse]
    var requests: [HTTPRequest] = []
    var active = 0
    var peak = 0
    let delay: Double
    var started: [CheckedContinuation<Void, Never>] = []
    init(_ responses: [HTTPResponse], delay: Double = 0) { self.responses = responses; self.delay = delay }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request); active += 1; peak = max(peak, active)
        let listeners = started; started = []; listeners.forEach { $0.resume() }
        defer { active -= 1 }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return responses.isEmpty ? HTTPResponse(status: 200) : responses.removeFirst()
    }
    func waitForStart() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { started.append($0) }
    }
    func snapshot() -> (count: Int, peak: Int, requests: [HTTPRequest]) { (requests.count, peak, requests) }
}
final class VirtualHTTPTime: Sendable {
    private struct State { var now: Double = 0; var delays: [Double] = [] }
    private let state = Mutex(State())
    func now() -> Double { state.withLock { $0.now } }
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        state.withLock { $0.now += seconds; $0.delays.append(seconds) }
        await Task.yield()
    }
    func advance(_ seconds: Double) { state.withLock { $0.now += seconds } }
    func delays() -> [Double] { state.withLock { $0.delays } }
}

@MainActor final class SourceTests: XCTestCase {
    let request = HTTPRequest(url: URL(string: "https://synthetic.invalid/catalog")!)
    func testRetriesJitterTokenBucketAndAccountIsolation() async throws {
        let clock = VirtualHTTPTime()
        var policy = HTTPPolicy(); policy.capacity = 1; policy.tokensPerSecond = 2; policy.baseDelay = 0.2
        let transport = SyntheticHTTP([HTTPResponse(status: 503), HTTPResponse(status: 429, headers: ["Retry-After": "1"]), HTTPResponse(status: 200)])
        let client = try ResilientHTTPClient(transport: transport, policy: policy, now: { clock.now() }, sleep: { try await clock.sleep($0) }, random: { 1 })
        let account = ProviderAccountID()
        let response = try await client.send(request, account: account)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(clock.delays().contains(0.2))
        XCTAssertTrue(clock.delays().contains(1))
        XCTAssertGreaterThanOrEqual(clock.now(), 1.5)
        let before = clock.now()
        _ = try await client.send(request, account: ProviderAccountID())
        XCTAssertEqual(clock.now(), before)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.count, 4)
    }
    func testMaximumTwoRequestsAcrossAccounts() async throws {
        let transport = SyntheticHTTP([], delay: 0.01)
        var policy = HTTPPolicy(); policy.capacity = 20; policy.tokensPerSecond = 1_000
        let client = try ResilientHTTPClient(transport: transport, policy: policy)
        let request = request
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = try await client.send(request, account: .init()) } }
            try await group.waitForAll()
        }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.count, 12)
        XCTAssertEqual(snapshot.peak, 2)
    }
    func testBreakerRejectsThenRecovers() async throws {
        let clock = VirtualHTTPTime()
        let transport = SyntheticHTTP([HTTPResponse(status: 503), HTTPResponse(status: 503), HTTPResponse(status: 200)])
        var policy = HTTPPolicy(); policy.retries = 0; policy.breakerThreshold = 2; policy.breakerCooldown = 10
        let client = try ResilientHTTPClient(transport: transport, policy: policy, now: { clock.now() }, sleep: { try await clock.sleep($0) })
        let account = ProviderAccountID()
        for _ in 0..<2 { do { _ = try await client.send(request, account: account); XCTFail("503 accepted") } catch {} }
        do { _ = try await client.send(request, account: account); XCTFail("Open breaker") } catch let error as HTTPFailure { XCTAssertEqual(error, .circuitOpen) }
        let blocked = await transport.snapshot()
        XCTAssertEqual(blocked.count, 2)
        clock.advance(11)
        let recovered = try await sendStatus(client, account)
        XCTAssertEqual(recovered, 200)
    }
    private func sendStatus(_ client: ResilientHTTPClient, _ account: ProviderAccountID) async throws -> Int { try await client.send(request, account: account).status }
    func testTimeoutAndCancellationReleaseTransportSlots() async throws {
        let transport = SyntheticHTTP([], delay: 10)
        var policy = HTTPPolicy(); policy.timeout = 0.02; policy.retries = 0
        let client = try ResilientHTTPClient(transport: transport, policy: policy)
        do { _ = try await client.send(request, account: .init()); XCTFail("Timeout missing") } catch let error as HTTPFailure { XCTAssertEqual(error, .timeout) }
        let cancelTransport = SyntheticHTTP([], delay: 10)
        let cancelClient = try ResilientHTTPClient(transport: cancelTransport)
        let request = request
        let task = Task { try await cancelClient.send(request, account: .init()) }
        await cancelTransport.waitForStart()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation missing") } catch is CancellationError {}
        let snapshot = await cancelTransport.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }
    func testJellyfinAndXtreamFixturesThroughAdapters() async throws {
        let jellyfin = Data(#"{"Items":[{"Id":"one","Name":"Synthetic Film","Type":"Movie","ProductionYear":2024,"ProviderIds":{"Imdb":"tt100","Tmdb":"100"},"MediaSources":[{"Id":"v1","Container":"mkv","Path":"/synthetic/file.mkv"}]}],"TotalRecordCount":1}"#.utf8)
        let transport = SyntheticHTTP([HTTPResponse(status: 200, body: jellyfin)])
        let http = try ResilientHTTPClient(transport: transport)
        let source = try JellyfinSource(partition: SourcePartition(account: .init(), library: "movies"), baseURL: URL(string: "https://synthetic.invalid")!, token: "synthetic-token", http: http)
        let page = try await source.fetchPage(token: nil)
        XCTAssertNil(page.nextToken)
        XCTAssertEqual(page.items.first?.externalIDs["imdb"], "tt100")
        XCTAssertEqual(page.items.first?.versions.first?.container, "mkv")
        let list = Data(#"[{"stream_id":"42","name":"Synthetic VOD 4K","container_extension":"mp4","tmdb":"100"}]"#.utf8)
        let details = Data(#"{"info":{"tmdb_id":100,"releasedate":"2024-01-01"},"movie_data":{"stream_id":42,"name":"Synthetic VOD","container_extension":"mkv"}}"#.utf8)
        let xtreamTransport = SyntheticHTTP([HTTPResponse(status: 200, body: list), HTTPResponse(status: 200, body: details)])
        let xtream = XtreamSource(partition: SourcePartition(account: .init(), library: "vod"), baseURL: URL(string: "https://synthetic.invalid")!, username: "fixture-user", password: "fixture-password", http: try ResilientHTTPClient(transport: xtreamTransport))
        let vod = try await xtream.fetchPage(token: nil)
        let info = try await xtream.details(vodID: "42")
        XCTAssertEqual(vod.items.first?.id, info.id)
        XCTAssertEqual(info.externalIDs["tmdb"], "100")
        let requests = await xtreamTransport.snapshot().requests
        XCTAssertEqual(URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "action" })?.value, "get_vod_info")
    }
    func testSyncFailureAndCancellationPreservePublishedGeneration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try SQLiteDatabase(path: folder.appendingPathComponent("sync.sqlite"))
        let catalog = try await CatalogStore.open(database: db)
        let partition = SourcePartition(account: .init(), library: "synthetic")
        let coordinator = SyncCoordinator(catalog: catalog)
        try await coordinator.sync(SyntheticSource(partition: partition, mode: .success))
        for mode in [SyntheticSource.Mode.failure, .cancel] {
            let task = Task { try await coordinator.sync(SyntheticSource(partition: partition, mode: mode)) }
            do { try await task.value; XCTFail("Incomplete sync published") } catch {}
            let page = try await catalog.page(partition: partition)
            XCTAssertEqual(page.items.map(\.id), ["one", "two"])
        }
        try await db.close()
    }
}
struct SyntheticSource: MediaSourceAdapter {
    enum Mode: Sendable { case success, failure, cancel }
    let partition: SourcePartition
    let capabilities: SourceCapabilities = [.movies]
    let mode: Mode
    func fetchPage(token: SyncToken?) async throws -> SourceCatalogPage {
        if token == nil { return SourceCatalogPage(items: [CanonicalMedia(id: "one", kind: .movie, title: "One")], nextToken: SyncToken("next")) }
        if mode == .failure { throw HTTPFailure.status(503) }
        if mode == .cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return SourceCatalogPage(items: [CanonicalMedia(id: "two", kind: .movie, title: "Two")], nextToken: nil)
    }
}
