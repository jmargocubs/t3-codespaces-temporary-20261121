#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// SwiftUI app delegate bridge used only so UIKit asks our shared coordinator
/// which orientations are currently allowed.
final class SiloAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientationCoordinator.shared.supportedOrientations
    }
}

enum PlayerScreenOrientation: Equatable {
    case portrait
    case landscape

    init?(interfaceOrientation: UIInterfaceOrientation) {
        if interfaceOrientation.isLandscape { self = .landscape }
        else if interfaceOrientation.isPortrait { self = .portrait }
        else { return nil }
    }

    var toggled: Self { self == .portrait ? .landscape : .portrait }
    var title: String { self == .portrait ? "Portrait" : "Landscape" }
    var mask: UIInterfaceOrientationMask { self == .portrait ? .portrait : .landscape }
}

/// Locking captures an exact orientation (including the landscape side);
/// explicit rotation moves that lock without unlocking it. The landscape lock
/// is persisted through `player.orientation_mode`, so a new session starts
/// locked when the last one was.
struct PlayerRotationState {
    private var isPlayerPresented = false
    private var isPlayerCovered = false
    var isPlayerActive: Bool { isPlayerPresented && !isPlayerCovered }
    private(set) var lockedOrientation: UIInterfaceOrientationMask?
    var isLocked: Bool { lockedOrientation != nil }

    mutating func activate(lockedOrientation: UIInterfaceOrientationMask? = nil) {
        isPlayerPresented = true
        isPlayerCovered = false
        self.lockedOrientation = lockedOrientation
    }

    /// The persisted mode this state maps to: locked to a landscape side is
    /// `landscapeLocked`; unlocked is `rotateFreely`. A portrait lock has no
    /// remote representation and leaves the stored mode unchanged.
    var persistedOrientationMode: PlayerOrientationMode? {
        guard let lockedOrientation else { return .rotateFreely }
        return lockedOrientation.isSubset(of: .landscape) ? .landscapeLocked : nil
    }

    mutating func deactivate() {
        isPlayerPresented = false
        isPlayerCovered = false
        lockedOrientation = nil
    }

    mutating func setPlayerCovered(_ covered: Bool) {
        guard isPlayerPresented else { return }
        isPlayerCovered = covered
    }

    mutating func toggleLock(at orientation: UIInterfaceOrientationMask) {
        guard isPlayerActive else { return }
        lockedOrientation = isLocked ? nil : orientation
    }

    mutating func manuallyRotate(to orientation: UIInterfaceOrientationMask) {
        guard isPlayerActive, isLocked else { return }
        lockedOrientation = orientation
    }
}

/// Which interface rotation the player asked for itself, so that one rotation runs without UIKit's
/// rotation animation.
///
/// Live TV full screen expanded from an inline player swaps its cover in one frame and rotates the
/// scene to landscape; closing it rotates back to portrait. Animated, that rotation spins the
/// outgoing layout against the black window (Build 50 recording, 1:13–1:25 and 3:13–3:19). A
/// rotation the device drives keeps the system animation: only the one the player requested,
/// toward the orientation it requested, is consumed here.
struct PlayerRotationTransitionPolicy: Equatable {
    private(set) var pending: PlayerScreenOrientation?

    /// The player asked the scene for `target`. A scene already there will not transition, so
    /// nothing is left pending to swallow a later rotation the device makes.
    mutating func requested(_ target: PlayerScreenOrientation, from current: PlayerScreenOrientation?) {
        pending = current == target ? nil : target
    }

    /// A rotation is starting toward `target` (nil when the size does not say). True once, for the
    /// rotation that was requested; a rotation the other way supersedes the request.
    mutating func transitionWillBegin(to target: PlayerScreenOrientation?) -> Bool {
        guard let pending else { return false }
        self.pending = nil
        return target == nil || target == pending
    }

    /// The geometry request failed, or a new player took over the orientation policy.
    mutating func cancel() { pending = nil }
}

/// Centralized orientation policy for the iOS app and player shell. Playback code
/// should stay unaware of this; the coordinator only manages UIKit masks and
/// scene geometry updates while the full-screen player is visible.
@MainActor
@Observable
final class PlayerOrientationCoordinator {
    static let shared = PlayerOrientationCoordinator()

    /// Browsing is portrait-only on iPhone. iPad keeps every orientation its
    /// Info.plist advertises so the split view and detail deck can rotate.
    static var appDefaultOrientations: UIInterfaceOrientationMask {
        browsingOrientations(isPad: UIDevice.current.userInterfaceIdiom == .pad)
    }

    static func browsingOrientations(isPad: Bool) -> UIInterfaceOrientationMask {
        isPad ? .allButUpsideDown : .portrait
    }

    private var rotationState = PlayerRotationState()
    @ObservationIgnored private var rotationTransition = PlayerRotationTransitionPolicy()
    /// Live TV full screen holds the scene in landscape because it asked to, not because the
    /// device turned; leaving it rotates back the same way.
    @ObservationIgnored private var isLiveTVLandscapeRequested = false
    @ObservationIgnored private var liveTVOrientationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isWatchScreenActive = false
    private(set) var suppressNaturalExpansionUntilUpright = false
    private(set) var observedOrientation: PlayerScreenOrientation = .portrait
    var isPlayerActive: Bool { rotationState.isPlayerActive }
    var isRotationLocked: Bool { rotationState.isLocked }

    var supportedOrientations: UIInterfaceOrientationMask {
        if !isPlayerActive && isWatchScreenActive { return .allButUpsideDown }
        return Self.orientationMask(isPlayerActive: isPlayerActive,
                                    lockedOrientation: rotationState.lockedOrientation)
    }

    /// The portrait watch frame permits native interface rotation without requesting geometry.
    /// UIKit therefore obeys system Portrait Orientation Lock; the manual Full Screen control
    /// still uses the existing explicit landscape override in the full-screen player.
    func watchScreenDidAppear() {
        isWatchScreenActive = true
        observeLiveTVOrientationChanges()
        refreshInterfaceOrientation()
        notifyActiveWindowsOfOrientationChange()
    }

    func watchScreenDidDisappear() {
        isWatchScreenActive = false
        if !isPlayerActive { stopObservingLiveTVOrientationChanges() }
        notifyActiveWindowsOfOrientationChange()
    }

    /// Exiting a manually requested landscape cover while still holding the phone sideways
    /// must not immediately re-open it through the automatic watch-screen path.
    func manualInlineCollapseRequested() {
        suppressNaturalExpansionUntilUpright = UIDevice.current.orientation.isLandscape
    }

    /// `browsingOrientations` defaults to `appDefaultOrientations`, resolved
    /// in the body: a default argument is evaluated outside the main actor.
    static func orientationMask(
        isPlayerActive: Bool, lockedOrientation: UIInterfaceOrientationMask? = nil,
        browsingOrientations: UIInterfaceOrientationMask? = nil
    ) -> UIInterfaceOrientationMask {
        // Info.plist must continue advertising landscape so video can use it.
        // The delegate restricts iPhone non-player pages to portrait at runtime.
        guard isPlayerActive else { return browsingOrientations ?? appDefaultOrientations }
        // Only the separate lock button restricts device-driven rotation.
        return lockedOrientation ?? .allButUpsideDown
    }

    static func geometryMask(
        isPlayerActive: Bool, preferredOrientation: UIInterfaceOrientationMask?,
        lockedOrientation: UIInterfaceOrientationMask? = nil,
        browsingOrientations: UIInterfaceOrientationMask? = nil
    ) -> UIInterfaceOrientationMask {
        let allowed = orientationMask(isPlayerActive: isPlayerActive, lockedOrientation: lockedOrientation,
                                      browsingOrientations: browsingOrientations)
        let requested = preferredOrientation?.intersection(allowed) ?? allowed
        // A queued landscape request cannot rotate a page after video exits.
        return requested.isEmpty ? allowed : requested
    }

    private init() {}

    func activatePlayer() {
        refreshInterfaceOrientation()
        forgetRequestedRotation()
        isWatchScreenActive = false
        // `player.orientation_mode` is the remote-persisted lock. Landscape
        // locked means the session opens locked to the preferred landscape
        // side; rotate freely means the lock starts off.
        let persistedLock: UIInterfaceOrientationMask? =
            PlayerSettings.shared.playerOrientationMode.isLandscapeLocked ? preferredLandscapeMask() : nil
        rotationState.activate(lockedOrientation: persistedLock)
        updateOrientationPolicy(preferredOrientation: persistedLock ?? deviceOrientationMask())
    }

    /// Live TV shares the app-level orientation bridge but deliberately does
    /// not read or persist the movie-player orientation preference.
    func activateLiveTVPlayer() {
        refreshInterfaceOrientation()
        forgetRequestedRotation()
        isWatchScreenActive = false
        rotationState.activate()
        observeLiveTVOrientationChanges()
        updateOrientationPolicy(preferredOrientation: deviceOrientationMask())
    }

    /// Live TV full screen expanded from an inline player: locked to landscape (either side, so
    /// the device can still flip between them) and rotated there in one geometry request. The
    /// lock is what keeps it landscape while the phone is held upright or Portrait Orientation
    /// Lock is on; an explicit request rotates the scene either way. `deactivatePlayer()` returns
    /// to the portrait browsing mask.
    func activateLiveTVLandscapePlayer() {
        refreshInterfaceOrientation()
        isWatchScreenActive = false
        rotationState.activate(lockedOrientation: Self.liveTVLandscapeLock)
        isLiveTVLandscapeRequested = true
        rotationTransition.requested(.landscape, from: currentScreenOrientation())
        observeLiveTVOrientationChanges()
        updateOrientationPolicy(preferredOrientation: preferredLandscapeMask())
    }

    /// Both landscape sides: the lock fixes the axis, not the side the phone is turned to.
    static let liveTVLandscapeLock: UIInterfaceOrientationMask = .landscape

    /// Requests a geometry change only while the Live TV cover is active. The
    /// scene's allowed mask remains both landscape sides, so device rotation
    /// continues to work and iOS can reject the request when rotation is locked.
    func requestLiveTVOrientation(_ orientation: PlayerScreenOrientation) {
        guard rotationState.isPlayerActive else { return }
        updateOrientationPolicy(preferredOrientation: orientation.mask)
    }

    func toggleLiveTVOrientation() {
        guard rotationState.isPlayerActive else { return }
        refreshInterfaceOrientation()
        requestLiveTVOrientation(observedOrientation.toggled)
    }

    func deactivatePlayer() {
        // Callers deactivate more than once (the close control, then the cover's disappearance);
        // only the first, which still holds landscape, asks for the unanimated return.
        if isLiveTVLandscapeRequested {
            isLiveTVLandscapeRequested = false
            rotationTransition.requested(.portrait, from: currentScreenOrientation())
        }
        rotationState.deactivate()
        if isWatchScreenActive { observeLiveTVOrientationChanges() }
        else { stopObservingLiveTVOrientationChanges() }
        updateOrientationPolicy(preferredOrientation: Self.appDefaultOrientations.contains(.portrait)
            ? .portrait : Self.appDefaultOrientations)
    }

    /// A browsing panel can cover a retained player without ending playback.
    /// Keep its rotation lock so returning to video restores the same policy.
    func setPlayerCovered(_ covered: Bool) {
        rotationState.setPlayerCovered(covered)
        updateOrientationPolicy(preferredOrientation: isPlayerActive
            ? rotationState.lockedOrientation ?? deviceOrientationMask()
            : Self.appDefaultOrientations)
    }

    /// Write the lock back to `player.orientation_mode` so it survives the
    /// session and stays aligned with Android and the settings contract.
    private func persistRotationLock() {
        guard let mode = rotationState.persistedOrientationMode,
              PlayerSettings.shared.playerOrientationMode != mode else { return }
        PlayerSettings.shared.setPlayerOrientationMode(mode)
    }

    var nextPlayerOrientation: PlayerScreenOrientation {
        observedOrientation.toggled
    }

    func refreshInterfaceOrientation() {
        guard let current = currentInterfaceOrientation(),
              let orientation = PlayerScreenOrientation(interfaceOrientation: current) else { return }
        observedOrientation = orientation
    }

    private func observeLiveTVOrientationChanges() {
        stopObservingLiveTVOrientationChanges()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let center = NotificationCenter.default
        let token = center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if UIDevice.current.orientation.isPortrait { self.suppressNaturalExpansionUntilUpright = false }
                self.refreshInterfaceOrientation()
            }
        }
        liveTVOrientationObservers.append(token)
    }

    private func stopObservingLiveTVOrientationChanges() {
        for token in liveTVOrientationObservers { NotificationCenter.default.removeObserver(token) }
        if !liveTVOrientationObservers.isEmpty { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        liveTVOrientationObservers.removeAll()
    }

    /// Read the real interface orientation for every tap. Explicit rotation
    /// works with the lock on or off, without touching the video session.
    func togglePlayerOrientation() {
        guard isPlayerActive else { return }
        refreshInterfaceOrientation()
        let target = nextPlayerOrientation
        let mask: UIInterfaceOrientationMask = target == .landscape ? preferredLandscapeMask() : .portrait
        rotationState.manuallyRotate(to: mask)
        persistRotationLock()
        updateOrientationPolicy(preferredOrientation: mask)
    }

    func toggleRotationLock() {
        guard isPlayerActive else { return }
        refreshInterfaceOrientation()
        let currentMask = currentInterfaceOrientation().flatMap(Self.exactMask) ?? observedOrientation.mask
        rotationState.toggleLock(at: currentMask)
        persistRotationLock()
        updateOrientationPolicy(preferredOrientation: rotationState.lockedOrientation ?? deviceOrientationMask())
    }

    private func updateOrientationPolicy(preferredOrientation: UIInterfaceOrientationMask) {
        let scenes = activeWindowScenes()
        for scene in scenes {
            for window in scene.windows {
                guard let rootViewController = window.rootViewController else { continue }
                notifyOrientationChange(for: rootViewController)
            }
        }

        let geometryMask = Self.geometryMask(isPlayerActive: isPlayerActive,
                                             preferredOrientation: preferredOrientation,
                                             lockedOrientation: rotationState.lockedOrientation,
                                             browsingOrientations: isWatchScreenActive ? .allButUpsideDown : nil)
        guard let scene = scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: geometryMask)) { [weak self] _ in
            guard let self else { return }
            // This handler runs only when the request fails: no rotation of ours will follow.
            self.rotationTransition.cancel()
            self.refreshInterfaceOrientation()
            for window in scene.windows {
                guard let rootViewController = window.rootViewController else { continue }
                self.notifyOrientationChange(for: rootViewController)
            }
        }
    }

    private func notifyOrientationChange(for viewController: UIViewController) {
        viewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let navigationController = viewController as? UINavigationController {
            navigationController.visibleViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if let tabBarController = viewController as? UITabBarController {
            tabBarController.selectedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if let presentedViewController = viewController.presentedViewController {
            notifyOrientationChange(for: presentedViewController)
        }
        for child in viewController.children {
            notifyOrientationChange(for: child)
        }
    }

    private func notifyActiveWindowsOfOrientationChange() {
        for scene in activeWindowScenes() {
            for window in scene.windows {
                if let root = window.rootViewController { notifyOrientationChange(for: root) }
            }
        }
    }

    private func activeWindowScenes() -> [UIWindowScene] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }
    }

    private func preferredLandscapeMask() -> UIInterfaceOrientationMask {
        if let interfaceOrientation = currentInterfaceOrientation() {
            switch interfaceOrientation {
            case .landscapeLeft:
                return .landscapeLeft
            case .landscapeRight:
                return .landscapeRight
            default:
                break
            }
        }

        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .landscapeRight
        }
    }

    private static func exactMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }

    private func deviceOrientationMask() -> UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return currentInterfaceOrientation().flatMap(Self.exactMask) ?? .portrait
        }
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        activeWindowScenes()
            .map(\.effectiveGeometry.interfaceOrientation)
            .first(where: { $0 != .unknown })
    }

    private func currentScreenOrientation() -> PlayerScreenOrientation? {
        currentInterfaceOrientation().flatMap(PlayerScreenOrientation.init(interfaceOrientation:))
    }

    private func forgetRequestedRotation() {
        isLiveTVLandscapeRequested = false
        rotationTransition.cancel()
    }

    /// Called as an interface rotation begins. True when it is the rotation the player asked for,
    /// which then runs without animation.
    func rotationTransitionWillBegin(to size: CGSize) -> Bool {
        let target: PlayerScreenOrientation? = size.width == size.height ? nil
            : (size.width > size.height ? .landscape : .portrait)
        return rotationTransition.transitionWillBegin(to: target)
    }
}

/// Sits at the root of the window so it sees every interface rotation, including the one that
/// follows a cover's dismissal, when the player that asked for it is gone. A rotation the player
/// requested runs with UIKit animations off until its transition completes; the cover already
/// changed in one frame, so the result is a cut instead of the window spinning on black.
/// Build 70: animations always come back on when the last such rotation ends (or at its deadline).
struct PlayerRotationTransitionHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        /// Build 70: one token per suppressed rotation (see `PlayerAnimationSuppression`).
        private var suppression = PlayerAnimationSuppression()

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isHidden = true
            self.view = view
        }

        override func viewWillTransition(to size: CGSize,
                                         with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            // UIKit forwards the container's new size; a square or empty size reads as unknown.
            let suppressAnimation = PlayerOrientationCoordinator.shared.rotationTransitionWillBegin(to: size)
            let token = suppressAnimation ? beginSuppression() : nil
            // The transition coordinator calls completion for finished and interrupted
            // transitions alike; the deadline covers one that never reports back.
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                if let token { self?.endSuppression(token, reason: "completed") }
                PlayerOrientationCoordinator.shared.refreshInterfaceOrientation()
            }
            if !queued {
                if let token { endSuppression(token, reason: "not_queued") }
                PlayerOrientationCoordinator.shared.refreshInterfaceOrientation()
            }
        }

        private func beginSuppression() -> Int {
            if !suppression.isSuppressing, !UIView.areAnimationsEnabled {
                // Nothing of ours holds them off; record it so a device journal can show who did.
                KyroLifecycleJournal.record("orientation", "animations_found_off")
            }
            let token = suppression.begin()
            UIView.setAnimationsEnabled(false)
            KyroLifecycleJournal.record("orientation", "animations_suppressed", "outstanding=\(suppression.outstanding.count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + PlayerAnimationSuppression.deadline) { [weak self] in
                self?.endSuppression(token, reason: "deadline")
            }
            return token
        }

        /// Animations always come back on with the last token. Build 69 restored the value read
        /// when the rotation began, which was `false` for an overlapping or nested rotation.
        private func endSuppression(_ token: Int, reason: String) {
            guard suppression.end(token) else { return }
            UIView.setAnimationsEnabled(true)
            KyroLifecycleJournal.record("orientation", "animations_restored", reason)
        }
    }
}
#endif
