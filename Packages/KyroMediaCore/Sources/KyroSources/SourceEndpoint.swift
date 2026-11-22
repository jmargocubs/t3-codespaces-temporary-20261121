import Foundation

public struct SourceEndpoint: Sendable {
  private let base: URL
  public init(_ base: URL) throws {
    guard ["https", "http"].contains(base.scheme?.lowercased() ?? ""),
      base.host != nil, base.user == nil, base.password == nil
    else { throw EndpointError.invalidURL }
    self.base = base
  }
  public func url(path: String, query: [URLQueryItem]) throws -> URL {
    guard
      var components = URLComponents(
        url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    else { throw EndpointError.invalidURL }
    components.fragment = nil
    components.queryItems = query
    guard let result = components.url else { throw EndpointError.invalidURL }
    return result
  }
  public enum EndpointError: Error { case invalidURL }
}
