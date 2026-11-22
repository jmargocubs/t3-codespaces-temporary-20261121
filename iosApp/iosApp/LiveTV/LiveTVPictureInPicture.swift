#if os(iOS)
import AetherEngine
import Observation

/// Holds the Live TV session weakly, so the session's own `isOtherVideoActive` closure can ask
/// whether the engaged Picture in Picture window is Live TV's.
final class LiveTVSessionReference: @unchecked Sendable {
    weak var session: LiveTVPlayerSession?
}

extension LiveTVPlayerSession {
    /// Binds the shared Picture in Picture coordinator to Live TV's engine, the way Silo's player
    /// binds its own. Idempotent for the same session; safe to call after every tune.
    ///
    /// Binding replaces whatever the coordinator held, so it is skipped while another player's
    /// window is up: that player keeps its window, and Live TV already refuses to tune then.
    func bindPictureInPicture(presentation: LiveTVPresentation) {
        let coordinator = PictureInPictureCoordinator.shared
        guard coordinator.isSupported,
              let aether = (engine as? AetherLiveTVEngine)?.engine else { return }
        if coordinator.isEngaged, !coordinator.ownsEngagedSession(self) { return }
        coordinator.bind(
            engine: aether,
            owner: self,
            onEngagementEnded: { [weak self, weak presentation] in
                guard let self, let presentation else { return }
                // A torn-down coordinator (sign-out, profile or server change) is never a window the
                // user closed, so it must stop playback even with a return pending.
                _ = presentation.engagementEnded(isStillBound: coordinator.isBound(to: self))
            },
            onRestoreUserInterface: { [weak presentation] completion in
                guard let presentation else {
                    completion(false)
                    return
                }
                if presentation.restoreReturnsToExpandedPlayer {
                    LiveTVCoverTransition.immediate { presentation.restoreRequested(completion: completion) }
                } else {
                    presentation.restoreRequested(completion: completion)
                }
            },
            // A start that did not happen leaves the button as it was; the stream is unaffected.
            onStartFailure: nil
        )
    }
}

#endif
