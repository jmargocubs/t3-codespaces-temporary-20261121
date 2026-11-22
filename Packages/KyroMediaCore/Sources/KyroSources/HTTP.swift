import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KyroFoundation

public struct HTTPRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
}
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) { self.status = status; self.headers = headers; self.body = body }
}
public protocol HTTPClient: Sendable {
    /// Implementations must cooperate with cancellation, including deadline expiry.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var outgoing = URLRequest(url: request.url)
        outgoing.allHTTPHeaderFields = request.headers
        let (data, response) = try await session.data(for: outgoing)
        guard let response = response as? HTTPURLResponse else { throw HTTPFailure.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return HTTPResponse(status: response.statusCode, headers: headers, body: data)
    }
}
public enum HTTPFailure: Error, Equatable { case invalidResponse, status(Int), timeout, circuitOpen, invalidPolicy }
public struct HTTPPolicy: Sendable {
    public var tokensPerSecond: Double = 5
    public var capacity: Double = 2
    public var retries: Int = 3
    public var baseDelay: Double = 0.2
    public var breakerThreshold: Int = 3
    public var breakerCooldown: Double = 30
    public var timeout: Double = 15
    public init() {}
}

/// Actor state owns per-account buckets and breakers. A shared gate bounds all
/// active transports to two, including retries and requests across accounts.
public actor ResilientHTTPClient {
    private let transport: any HTTPClient
    private let policy: HTTPPolicy
    private let now: @Sendable () -> Double
    private let sleep: @Sendable (Double) async throws -> Void
    private let random: @Sendable () -> Double
    private var active = 0
    private struct Account {
        var tokens: Double
        var updated: Double
        var failures = 0
        var openUntil: Double?
        var probe = false
    }
    private var accounts: [ProviderAccountID: Account] = [:]
    public init(transport: any HTTPClient, policy: HTTPPolicy = .init(), now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }, random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) throws {
        guard policy.tokensPerSecond.isFinite, policy.tokensPerSecond > 0, policy.capacity.isFinite, policy.capacity >= 1, (0...10).contains(policy.retries), policy.baseDelay.isFinite, policy.baseDelay >= 0, policy.breakerThreshold > 0, policy.breakerCooldown.isFinite, policy.breakerCooldown > 0, policy.timeout.isFinite, policy.timeout > 0 else { throw HTTPFailure.invalidPolicy }
        self.transport = transport; self.policy = policy; self.now = now; self.sleep = sleep; self.random = random
    }
    public func send(_ request: HTTPRequest, account: ProviderAccountID) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var state = accounts[account] ?? Account(tokens: policy.capacity, updated: now())
        if let until = state.openUntil {
            guard now() >= until, !state.probe else { throw HTTPFailure.circuitOpen }
            state.probe = true
        }
        accounts[account] = state
        do {
            for attempt in 0...policy.retries {
                try await acquire(account)
                let response: HTTPResponse
                do {
                    response = try await Self.timed(transport, request, timeout: policy.timeout)
                    active -= 1
                } catch {
                    active -= 1
                    if error is CancellationError { throw error }
                    if attempt == policy.retries { throw error }
                    try await backoff(attempt: attempt, retryAfter: nil)
                    continue
                }
                if (200..<300).contains(response.status) {
                    accounts[account]?.failures = 0; accounts[account]?.openUntil = nil; accounts[account]?.probe = false
                    return response
                }
                let transient = response.status == 429 || (500..<600).contains(response.status)
                guard transient, attempt < policy.retries else { throw HTTPFailure.status(response.status) }
                let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Double($0.value) }
                try await backoff(attempt: attempt, retryAfter: retryAfter)
            }
            throw HTTPFailure.invalidResponse
        } catch {
            accounts[account]?.probe = false
            if !(error is CancellationError) {
                accounts[account]?.failures += 1
                if (accounts[account]?.failures ?? 0) >= policy.breakerThreshold { accounts[account]?.openUntil = now() + policy.breakerCooldown }
            }
            throw error
        }
    }
    private func acquire(_ account: ProviderAccountID) async throws {
        while true {
            try Task.checkCancellation()
            var state = accounts[account]!
            let instant = now()
            state.tokens = min(policy.capacity, state.tokens + max(0, instant - state.updated) * policy.tokensPerSecond)
            state.updated = instant
            if active < 2, state.tokens >= 1 {
                state.tokens -= 1; accounts[account] = state; active += 1; return
            }
            accounts[account] = state
            let delay = state.tokens < 1 ? (1 - state.tokens) / policy.tokensPerSecond : 0.001
            try await sleep(delay)
        }
    }
    private func backoff(attempt: Int, retryAfter: Double?) async throws {
        let jitter = max(0, min(1, random()))
        let delay = min(60, policy.baseDelay * pow(2, Double(attempt))) * (0.5 + jitter * 0.5)
        let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? min(60, $0) : nil } ?? 0
        try await sleep(max(serverDelay, delay))
    }
    private static func timed(_ client: any HTTPClient, _ request: HTTPRequest, timeout: Double) async throws -> HTTPResponse {
        try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask { try await client.send(request) }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw HTTPFailure.timeout }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw HTTPFailure.invalidResponse }
            return first
        }
    }
}
