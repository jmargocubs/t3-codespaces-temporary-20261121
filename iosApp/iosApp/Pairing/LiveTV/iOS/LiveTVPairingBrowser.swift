#if os(iOS)
import Foundation
import Network
import Observation

/// Finds Apple TVs that are currently offering to receive a Live TV provider, over Bonjour. A TV
/// only advertises while its pairing screen is open, and the public session id travels in the
/// Bonjour record. The secret pairing code never does; the person types it from the TV screen.
@MainActor
@Observable
final class LiveTVPairingBrowser {
    struct TV: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let sessionID: String
    }

    private(set) var tvs: [TV] = []
    private(set) var isBrowsing = false
    private(set) var isDenied = false
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LiveTVPairing.bonjourType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.isBrowsing = true
                case .failed, .cancelled: self.isBrowsing = false
                case .waiting: self.isDenied = true
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.tv(from:))
            Task { @MainActor in self?.tvs = found.sorted { $0.name < $1.name } }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        tvs = []
    }

    nonisolated private static func tv(from result: NWBrowser.Result) -> TV? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let record) = result.metadata,
              let sid = record.dictionary["sid"],
              let data = LiveTVPairingEncoding.data(base64URL: sid), data.count == 16,
              record.dictionary["v"] == String(LiveTVPairing.version) else { return nil }
        let displayName = record.dictionary["n"].flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } ?? name
        return TV(id: sid, name: displayName, endpoint: result.endpoint, sessionID: sid)
    }
}
#endif
