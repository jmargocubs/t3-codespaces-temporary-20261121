import Foundation

/// Build 65: the Picture in Picture requests that outlive a single AVKit callback.
///
/// Build 62–64 kept these as loose flags that only a did-start or a failed start cleared. When AVKit
/// abandoned a start (the viewer came straight back mid-swipe and the window never finished
/// starting), the "stop once started" request stayed armed, and the next automatic window, started
/// by the next swipe to Home, was stopped the moment it appeared. Every terminal callback now resets
/// the state, and a return stop only runs while the app is really in the foreground.
struct PictureInPictureTransition: Equatable {
    enum ApplicationState: Equatable, CustomStringConvertible {
        case active, inactive, background
        var description: String {
            switch self {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            }
        }
    }

    enum StartAction: Equatable, CustomStringConvertible {
        /// Leave the window up.
        case none
        /// The player's own control started it: the presentation hands the stream to the window.
        case announceControlStart
        /// Close it now (a source change, or the app is back in front of its player).
        case stop
        /// Close it when the app finishes becoming active.
        case stopWhenActive

        var description: String {
            switch self {
            case .none: "none"
            case .announceControlStart: "control_start"
            case .stop: "stop"
            case .stopWhenActive: "stop_when_active"
            }
        }
    }

    /// The pending start came from the PiP button rather than from leaving the app.
    private(set) var isStartingFromControl = false
    /// A stop was asked for while the window was still starting.
    private(set) var stopsOnceStarted = false
    /// That stop is a return to the app, so it applies only with the app in front.
    private(set) var stopRequiresActiveApplication = false
    /// The return stop is waiting for did-become-active.
    private(set) var stopsWhenActive = false

    mutating func controlStartRequested() {
        isStartingFromControl = true
    }

    /// AVKit announced a start. An automatic start happens as the app resigns active; a control
    /// start only while it is active, so a leftover control request cannot mislabel a swipe home.
    mutating func willStart(application: ApplicationState) {
        stopsOnceStarted = false
        stopRequiresActiveApplication = false
        stopsWhenActive = false
        if application != .active { isStartingFromControl = false }
    }

    mutating func stopRequestedWhileStarting(requiresActiveApplication: Bool) {
        if stopsOnceStarted {
            // A deliberate close wins over a return-only close.
            stopRequiresActiveApplication = stopRequiresActiveApplication && requiresActiveApplication
        } else {
            stopsOnceStarted = true
            stopRequiresActiveApplication = requiresActiveApplication
        }
    }

    mutating func deferStopUntilActive() {
        stopsWhenActive = true
    }

    mutating func didStart(stopForSourceChange: Bool, application: ApplicationState) -> StartAction {
        let fromControl = isStartingFromControl
        let wantsStop = stopsOnceStarted
        let returnOnly = stopRequiresActiveApplication
        isStartingFromControl = false
        stopsOnceStarted = false
        stopRequiresActiveApplication = false
        if stopForSourceChange { return .stop }
        if wantsStop {
            guard returnOnly else { return .stop }
            switch application {
            case .active:
                return .stop
            case .inactive:
                stopsWhenActive = true
                return .stopWhenActive
            case .background:
                // The viewer left again before the window landed: it is now the only picture.
                return fromControl ? .announceControlStart : .none
            }
        }
        return fromControl ? .announceControlStart : .none
    }

    mutating func didStop() {
        self = PictureInPictureTransition()
    }

    mutating func failedToStart() {
        self = PictureInPictureTransition()
    }

    /// True once, when a deferred return stop is due.
    mutating func applicationDidBecomeActive() -> Bool {
        defer { stopsWhenActive = false }
        return stopsWhenActive
    }

    mutating func applicationDidEnterBackground() {
        stopsWhenActive = false
        if stopRequiresActiveApplication {
            stopsOnceStarted = false
            stopRequiresActiveApplication = false
        }
    }
}
