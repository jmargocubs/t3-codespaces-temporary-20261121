import Foundation

/// Provider-owned media (IPTV VOD) the shared player opens directly, without a Silo session.
///
/// `url` can carry provider credentials in its path. It is handed to Aether only; the player
/// never logs it, shows it, or sends it to the Silo server.
struct ExternalPlaybackRequest: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let sourceLabel: String
    let startPosition: Double
    /// Runs once after a failed open, when the engine has released the source, and reports what
    /// the provider actually answered. Nil skips the probe.
    let probe: (@MainActor () async -> ExternalStreamProbeReport?)?
    /// Position, duration and whether the item ended, when the player closes after playing.
    let onFinish: (@MainActor (_ position: Double, _ duration: Double, _ ended: Bool) -> Void)?

    init(id: UUID = UUID(), url: URL, title: String, sourceLabel: String, startPosition: Double = 0,
         probe: (@MainActor () async -> ExternalStreamProbeReport?)? = nil,
         onFinish: (@MainActor (_ position: Double, _ duration: Double, _ ended: Bool) -> Void)? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.sourceLabel = sourceLabel
        self.startPosition = startPosition
        self.probe = probe
        self.onFinish = onFinish
    }

    /// The same request reopened at `position`, keeping its identity for a retry.
    func resuming(at position: Double) -> ExternalPlaybackRequest {
        ExternalPlaybackRequest(id: id, url: url, title: title, sourceLabel: sourceLabel,
                                startPosition: position.isFinite ? max(0, position) : 0,
                                probe: probe, onFinish: onFinish)
    }
}
