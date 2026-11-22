import SwiftUI
import UIKit

enum KyroLiveTVNavigation {
    /// Drawn for iPhone. iPad keeps the existing Live TV header navigation.
    @MainActor
    static var isSupported: Bool { UIDevice.current.userInterfaceIdiom == .phone }
}

extension View {
    /// Kyro's Live TV navigation around a Live TV screen, in the chosen style.
    /// Classic puts the screen inside the Media Server's own tab bar
    /// (`SiloTabBar`); the floating styles draw only their handle over it, so
    /// scrolling, the guide grid and channel cards underneath behave as before.
    /// Exactly one of the two is ever in the hierarchy.
    @ViewBuilder
    func kyroLiveTVNavigation(isEnabled: Bool, active: KyroLiveTVDestination,
                              navigate: @escaping (KyroLiveTVDestination) -> Void) -> some View {
        if isEnabled && KyroLiveTVNavigation.isSupported {
            modifier(KyroLiveTVNavigationChrome(store: .shared, active: active, navigate: navigate))
        } else {
            self
        }
    }
}

/// What a Live TV screen needs to draw the navigation: whether it applies,
/// and the one routing function every style uses.
struct KyroLiveTVNavigationRoute {
    let isEnabled: Bool
    let navigate: (KyroLiveTVDestination) -> Void
}

extension View {
    @ViewBuilder
    func kyroLiveTVNavigation(_ route: KyroLiveTVNavigationRoute?, active: KyroLiveTVDestination) -> some View {
        if let route {
            kyroLiveTVNavigation(isEnabled: route.isEnabled, active: active, navigate: route.navigate)
        } else {
            self
        }
    }
}

private struct KyroLiveTVNavigationChrome: ViewModifier {
    @Bindable var store: KyroLiveTVNavigationStore
    let active: KyroLiveTVDestination
    let navigate: (KyroLiveTVDestination) -> Void

    func body(content: Content) -> some View {
        if KyroUnifiedNavigation.isActive {
            // The application shell owns navigation in unified mode. Live TV
            // keeps its contextual routes, but contributes no second bar.
            content
        } else if store.preferences.style.isFloating {
            content.overlay {
                KyroLiveTVNavigationOverlay(store: store, active: active, navigate: navigate)
            }
        } else {
            KyroLiveTVClassicNavigation(store: store, active: active, navigate: navigate) { content }
        }
    }
}

/// Classic: the Media Server's bottom tab bar, reused as is, over Live TV's
/// visible destinations in the user's order. Choosing a tab goes through the
/// same `navigate` as the floating styles, and the selected tab is always the
/// screen Live TV is showing, so switching styles never moves the user.
///
/// The screen sits in the tab of the destination it shows. A destination the
/// user hid (reached from the header) shows under Home. Other tabs stay empty
/// until chosen, so the screen exists once.
struct KyroLiveTVClassicNavigation<Screen: View>: View {
    @Bindable var store: KyroLiveTVNavigationStore
    let active: KyroLiveTVDestination
    let navigate: (KyroLiveTVDestination) -> Void
    @ViewBuilder let screen: Screen

    var body: some View {
        let destinations = store.preferences.visibleDestinations
        let shown = destinations.contains(active) ? active : .home
        SiloTabBar(
            items: destinations,
            selection: Binding(get: { shown.id }, set: { id in
                guard let destination = KyroLiveTVDestination(rawValue: id), destination != shown else { return }
                navigate(destination)
            }),
            title: \.title,
            icon: \.systemImage,
            selectedIcon: \.activeSystemImage
        ) { destination in
            if destination == shown {
                screen
            } else {
                // The page the chosen screen draws, so a tab switch never flashes black.
                SiloPageBackdrop()
            }
        }
        .tint(KyroTheme.shellTint)
    }
}

/// Both navigation styles over one store. The collapsed handle can be
/// long-pressed and dragged to any edge, where it snaps; a tap opens the
/// destinations; a quick drag from the handle opens them and scrubs, and
/// lifting the finger chooses.
///
/// The handle is deliberately not a `Button`. A high-priority drag owns
/// movement and a simultaneous tap covers stationary touches that SwiftUI's
/// zero-distance drag does not always report. Neither recognizer can start
/// navigation while a move is in progress.
struct KyroLiveTVNavigationOverlay: View {
    @Bindable var store: KyroLiveTVNavigationStore
    let active: KyroLiveTVDestination
    let navigate: (KyroLiveTVDestination) -> Void

    static let coordinateSpace = "kyroLiveTVNavigation"
    /// A faded handle is subtle but never invisible or untappable.
    static let fadedOpacity = 0.42
    static let expandedIdleDelay: Duration = .seconds(8)
    static let fadeDelay: Duration = .seconds(3)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase

    @GestureState private var isTouchingHandle = false
    @State private var handleTouch: HandleTouch = .idle
    @State private var dragLocation: CGPoint?
    @State private var pressTimer: Task<Void, Never>?
    @State private var pressStart: Date?
    @State private var gestureStartTime: Date?
    /// A stationary hold arms repositioning, but does not consume a tap until
    /// the finger actually moves. This also avoids slow event delivery turning
    /// an ordinary touch into a false drag.
    @State private var isDragArmed = false
    @State private var isRepositioning = false
    /// The overlay's bounds, for the cancelled-touch path that runs outside layout.
    @State private var bounds: CGRect = .zero
    @State private var traceRecorder = KyroNavigationHandleTraceRecorder()
    @State private var scrubIndex: Int?
    @State private var isHandleScrubbing = false
    @State private var isFaded = false
    @State private var activity = 0
    @State private var lastSelection = Date.distantPast
    @State private var lastTouchTap = Date.distantPast
    @State private var selectionTick = 0
    @State private var snapTick = 0
    @State private var liftTick = 0

    private var preferences: KyroLiveTVNavigationPreferences { store.preferences }
    private var destinations: [KyroLiveTVDestination] { preferences.visibleDestinations }
    private var style: KyroLiveTVNavigationStyle { preferences.style }
    private var anchor: KyroNavigationAnchor { preferences.anchor(for: style) }
    private var isExpanded: Bool { store.isExpanded }

    var body: some View {
        // The bounds respect the keyboard, so while searching the handle rides above it
        // instead of hiding under it.
        GeometryReader { proxy in
            let geometry = KyroNavigationGeometry(bounds: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear { bounds = geometry.bounds }
                    .onChange(of: geometry.bounds) { _, new in bounds = new }
                if isExpanded {
                    scrim
                        .transition(.opacity)
                }
                switch style {
                case .glassDock: dock(geometry)
                case .thumbFan: fan(geometry)
                case .classic: EmptyView()
                }
                #if DEBUG
                debugTraceElement
                #endif
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.coordinateSpace))
        }
        .sensoryFeedback(trigger: scrubIndex) { _, new in
            preferences.hapticsEnabled && new != nil ? .selection : nil
        }
        .sensoryFeedback(trigger: selectionTick) { _, _ in
            preferences.hapticsEnabled ? .impact(weight: .light) : nil
        }
        .sensoryFeedback(trigger: snapTick) { _, _ in
            preferences.hapticsEnabled ? .impact(flexibility: .soft, intensity: 0.8) : nil
        }
        .sensoryFeedback(trigger: liftTick) { _, _ in
            preferences.hapticsEnabled ? .impact(weight: .medium) : nil
        }
        .task(id: IdleKey(expanded: isExpanded, faded: isFaded, activity: activity,
                          behavior: preferences.idleBehavior, voiceOver: voiceOver,
                          repositioning: isRepositioning)) {
            await runIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            store.isExpanded = false
            isFaded = false
        }
        .onChange(of: style) { _, _ in
            scrubIndex = nil
            noteActivity()
        }
        .onChange(of: preferences.idleBehavior) { _, _ in isFaded = false }
        .onChange(of: isTouchingHandle) { _, touching in
            guard !touching else { return }
            // Wait a turn so a normal end, which runs onEnded, settles first.
            Task { @MainActor in
                if !isTouchingHandle { cancelHandleTouch() }
            }
        }
    }

    // MARK: Adaptive Glass Dock

    @ViewBuilder
    private func dock(_ geometry: KyroNavigationGeometry) -> some View {
        let layout = geometry.dockLayout(for: anchor, itemCount: destinations.count)
        let handleCenter = dragLocation ?? geometry.center(for: anchor)
        // The open dock replaces the handle. A drag that started on the handle keeps it,
        // invisible, until the finger lifts, so scrubbing can continue across the dock.
        // Otherwise it leaves the hierarchy: a handle faded back in from zero opacity
        // can stop taking touches.
        if !isExpanded || isHandleScrubbing {
            handle(geometry, center: handleCenter, symbol: active.activeSystemImage,
                   shape: RoundedRectangle(cornerRadius: 19, style: .continuous),
                   scrubCenters: layout.itemCenters, itemSize: layout.itemSize)
                .opacity(isExpanded ? 0 : 1)
                .accessibilityHidden(isExpanded)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        }
        if isExpanded {
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.clear)
                    .kyroGlass(Capsule(), glow: true)
                    .contentShape(Capsule())
                    .frame(width: layout.frame.width, height: layout.frame.height)
                    .position(x: layout.frame.midX, y: layout.frame.midY)
                    .accessibilityHidden(true)
                ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                    item(destination, index: index, size: layout.itemSize)
                        .position(layout.itemCenters[index])
                }
                if let scrubIndex, layout.itemCenters.indices.contains(scrubIndex) {
                    scrubCallout(destinations[scrubIndex], at: layout.itemCenters[scrubIndex],
                                 itemSize: layout.itemSize, geometry: geometry)
                }
            }
            .simultaneousGesture(scrubGesture(centers: layout.itemCenters, itemSize: layout.itemSize))
            .allowsHitTesting(isExpanded)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kyroLiveTVNavDock")
            .accessibilityAction(.escape) { collapse() }
            .transition(expandTransition(from: geometry.center(for: anchor), in: geometry.bounds.size))
        }
    }

    // MARK: Thumb Fan

    @ViewBuilder
    private func fan(_ geometry: KyroNavigationGeometry) -> some View {
        let layout = geometry.fanLayout(for: anchor, itemCount: destinations.count)
        let handleCenter = dragLocation ?? geometry.center(for: anchor)
        // The container always exists so each item can fly out of the orb on its own.
        ZStack(alignment: .topLeading) {
            if isExpanded {
                ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                    item(destination, index: index, size: KyroNavigationGeometry.itemSize, glass: true)
                        .position(layout.itemCenters[index])
                        .allowsHitTesting(isExpanded)
                        .transition(fanItemTransition(from: layout.origin, to: layout.itemCenters[index], index: index))
                }
                if let scrubIndex, layout.itemCenters.indices.contains(scrubIndex) {
                    scrubCallout(destinations[scrubIndex], at: layout.itemCenters[scrubIndex],
                                 itemSize: KyroNavigationGeometry.itemSize, geometry: geometry)
                }
            }
        }
        .simultaneousGesture(scrubGesture(centers: layout.itemCenters, itemSize: KyroNavigationGeometry.itemSize))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroLiveTVNavFan")
        .accessibilityAction(.escape) { collapse() }
        handle(geometry, center: handleCenter, symbol: isExpanded ? "xmark" : active.activeSystemImage,
               shape: Circle(), isOrb: true, scrubCenters: layout.itemCenters, itemSize: KyroNavigationGeometry.itemSize)
    }

    // MARK: Handle

    private func handle<S: InsettableShape>(_ geometry: KyroNavigationGeometry, center: CGPoint, symbol: String,
                                            shape: S, isOrb: Bool = false, scrubCenters: [CGPoint],
                                            itemSize: CGFloat) -> some View {
        let size = KyroNavigationGeometry.handleDiameter
        return Image(systemName: symbol)
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(KyroTheme.textPrimary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .kyroGlass(shape, glow: isRepositioning || isDragArmed)
            .overlay {
                if isOrb {
                    shape.strokeBorder(AngularGradient(colors: [KyroTheme.silver, KyroTheme.accentInk, KyroTheme.accent,
                                                                KyroTheme.silver],
                                                       center: .center),
                                       lineWidth: 1.5)
                        .opacity(0.75)
                }
            }
            .overlay {
                // Picked up: an electric-blue ring, so the hold visibly worked even
                // with haptics off.
                if isRepositioning || isDragArmed {
                    shape.strokeBorder(KyroTheme.accentInk, lineWidth: 2.5)
                        .shadow(color: KyroTheme.accent.opacity(0.8), radius: 8)
                        .transition(.opacity)
                }
            }
            .scaleEffect(handleScale)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: handleScale)
            .contentShape(shape)
            .opacity(isFaded && !isExpanded ? Self.fadedOpacity : 1)
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .named(Self.coordinateSpace))
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { rendered in
                if isRepositioning { traceRecorder.noteRendered(rendered, finger: dragLocation) }
            }
            .highPriorityGesture(handleGesture(geometry, centers: scrubCenters, itemSize: itemSize))
            // A zero-distance DragGesture does not receive every stationary
            // tap on iOS. Keep a tap recognizer on the same visible hit area;
            // movement still belongs to the drag gesture below.
            .simultaneousGesture(TapGesture().onEnded { registerTouchTap() })
            .position(center)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isExpanded ? "Close Live TV navigation" : "Live TV navigation")
            .accessibilityValue(isExpanded ? "" : active.title)
            .accessibilityHint(isExpanded ? "" : "Shows \(destinations.map(\.title).formatted(.list(type: .and))).")
            .accessibilityIdentifier("kyroLiveTVNavHandle")
            .accessibilityAction { handleTapped() }
            .accessibilityActions {
                if !isExpanded {
                    ForEach(destinations) { destination in
                        Button("Go to \(destination.title)") { select(destination) }
                    }
                    if preferences.allowsDragging {
                        ForEach(KyroNavigationEdge.allCases.filter { $0 != anchor.edge }) { edge in
                            Button("Move to \(edge.title) Edge") { move(to: edge) }
                        }
                    }
                }
            }
    }

    /// Pressed, lifted while being moved, or at rest.
    private var handleScale: CGFloat {
        if reduceMotion { return 1 }
        if isRepositioning { return 1.12 }
        if isDragArmed { return 1.08 }
        return handleTouch == .pending ? 0.94 : 1
    }

    private func handleTapped() {
        if isFaded && !isExpanded {
            withAnimation(.easeOut(duration: 0.2)) { isFaded = false }
        }
        setExpanded(!isExpanded)
    }

    private func registerTouchTap() {
        // On OS versions where the zero-distance drag also ends for a tap,
        // both recognizers may report the same lift. Activate only once.
        let now = Date()
        // The drag recognizer can deliver its end after TapGesture by more than
        // one run-loop turn on a busy simulator/device. Keep the two reports
        // of one lift from toggling the menu twice.
        guard now.timeIntervalSince(lastTouchTap) > 1.0 else { return }
        lastTouchTap = now
        if handleTouch == .idle {
            traceRecorder.begin()
            traceRecorder.noteUpdate()
            store.lastHandleTrace = traceRecorder.finish(.tap)
        }
        handleTapped()
    }

    #if DEBUG
    /// Debug builds only: the last handle trace, for the UI tests.
    private var debugTraceElement: some View {
        Text(store.lastHandleTrace?.summary ?? "none")
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityLabel("Navigation trace")
            .accessibilityValue(store.lastHandleTrace?.summary ?? "none")
            .accessibilityIdentifier("kyroLiveTVNavTrace")
    }
    #endif

    // MARK: Destinations

    private func item(_ destination: KyroLiveTVDestination, index: Int, size: CGFloat, glass: Bool = false) -> some View {
        let isActive = destination == active
        let isTarget = scrubIndex == index
        return Button { select(destination) } label: {
            ZStack {
                if glass {
                    Circle().fill(Color.clear).kyroGlass(Circle(), glow: isActive).frame(width: size - 4, height: size - 4)
                }
                if isActive {
                    Circle()
                        .fill(KyroTheme.activeGradient)
                        .overlay(Circle().strokeBorder(KyroTheme.accentInk.opacity(0.7), lineWidth: 1))
                        .shadow(color: KyroTheme.accent.opacity(0.6), radius: 10)
                        .frame(width: size - 8, height: size - 8)
                } else if isTarget {
                    Circle().fill(KyroTheme.selectedFill).frame(width: size - 8, height: size - 8)
                }
                Image(systemName: isActive ? destination.activeSystemImage : destination.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isActive ? KyroTheme.textPrimary : KyroTheme.silver)
            }
            .frame(width: size, height: size)
            .scaleEffect(isTarget && !reduceMotion ? 1.12 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(KyroPressButtonStyle())
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityAction(named: "Close Navigation") { collapse() }
        .accessibilityIdentifier("kyroLiveTVNav.\(destination.rawValue)")
        .accessibilityShowsLargeContentViewer {
            Label(destination.title, systemImage: destination.systemImage)
        }
    }

    private func scrubCallout(_ destination: KyroLiveTVDestination, at center: CGPoint, itemSize: CGFloat,
                              geometry: KyroNavigationGeometry) -> some View {
        let gap = itemSize / 2 + 10
        let bounds = geometry.bounds
        let label = Text(destination.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .kyroGlass(Capsule())
            .fixedSize()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        return Group {
            switch anchor.edge {
            case .right:
                label.frame(width: 200, alignment: .trailing).position(x: center.x - gap - 100, y: center.y)
            case .left:
                label.frame(width: 200, alignment: .leading).position(x: center.x + gap + 100, y: center.y)
            case .top:
                label.frame(height: 44, alignment: .top)
                    .position(x: min(max(center.x, bounds.minX + 70), bounds.maxX - 70), y: center.y + gap + 22)
            case .bottom:
                label.frame(height: 44, alignment: .bottom)
                    .position(x: min(max(center.x, bounds.minX + 70), bounds.maxX - 70), y: center.y - gap - 22)
            }
        }
        .transition(.opacity)
    }

    private var scrim: some View {
        Color.black.opacity(0.28)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            // While it fades out it must not swallow the next tap on the handle.
            .allowsHitTesting(isExpanded)
            .onTapGesture { collapse() }
            // A full-screen element would win VoiceOver's touch exploration over the
            // destinations. VoiceOver closes with the escape gesture or each item's
            // Close Navigation action instead.
            .accessibilityHidden(true)
    }

    // MARK: Gestures

    /// What a touch on the handle turned out to be. Movement is decided by
    /// the drag gesture; a separate tap reports stationary touches only:
    /// moving 10pt within 0.35s scrubs; a stationary 0.35s hold arms a move,
    /// and the handle follows only after movement. Lifting without moving is
    /// still a tap, even if event delivery was delayed.
    private enum HandleTouch: Equatable {
        case idle, pending, scrubbing, repositioning, ignored
    }

    static let pickUpDelay: TimeInterval = 0.35
    /// Ignore simulator/device finger jitter while a hold is stationary; a
    /// deliberate drag still clears this quickly.
    static let scrubSlop: CGFloat = 18

    private func handleGesture(_ geometry: KyroNavigationGeometry, centers: [CGPoint], itemSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
            .updating($isTouchingHandle) { _, state, _ in state = true }
            .onChanged { value in
                if handleTouch == .idle { traceRecorder.begin() }
                traceRecorder.noteUpdate()
                switch handleTouch {
                case .idle:
                    handleTouch = .pending
                    // Use the wall-clock at recognition start. `DragGesture.Value.time`
                    // is not guaranteed to share Date()'s epoch on every OS build.
                    pressStart = Date()
                    gestureStartTime = value.time
                    pressTimer?.cancel()
                    pressTimer = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.pickUpDelay))
                        guard !Task.isCancelled, handleTouch == .pending else { return }
                        if preferences.allowsDragging && !isExpanded {
                            isDragArmed = true
                            traceRecorder.noteArmed(after: Self.pickUpDelay)
                            liftTick += 1
                        }
                    }
                case .pending:
                    guard hypot(value.translation.width, value.translation.height) > Self.scrubSlop else { return }
                    pressTimer?.cancel()
                    // Decide from the touches' own timestamps: if the main thread was busy, the
                    // still hold and the first movement can arrive together, before the timer ran.
                    let held = gestureStartTime.map { value.time.timeIntervalSince($0) } ?? 0
                    if (held >= Self.pickUpDelay || isDragArmed),
                       preferences.allowsDragging, !isExpanded {
                        handleTouch = .repositioning
                        traceRecorder.notePickUp(isDragArmed ? .hold : .movement,
                                                 after: held, at: geometry.center(for: anchor))
                        if !isDragArmed { liftTick += 1 }
                        beginRepositioning()
                        dragLocation = geometry.clamped(value.location)
                        return
                    }
                    guard preferences.thumbScrubbing else {
                        handleTouch = .ignored
                        return
                    }
                    handleTouch = .scrubbing
                    isHandleScrubbing = true
                    if !isExpanded { setExpanded(true) }
                    updateScrub(at: value.location, centers: centers, itemSize: itemSize)
                case .scrubbing:
                    updateScrub(at: value.location, centers: centers, itemSize: itemSize)
                case .repositioning:
                    dragLocation = geometry.clamped(value.location)
                case .ignored:
                    break
                }
            }
            .onEnded { value in
                finishHandleTouch(geometry, at: value.location, centers: centers, itemSize: itemSize)
            }
    }

    private func updateScrub(at location: CGPoint, centers: [CGPoint], itemSize: CGFloat) {
        let index = KyroNavigationGeometry.index(at: location, in: centers, itemSize: itemSize)
        if index != scrubIndex { scrubIndex = index }
    }

    private func finishHandleTouch(_ geometry: KyroNavigationGeometry, at location: CGPoint,
                                   centers: [CGPoint], itemSize: CGFloat) {
        pressTimer?.cancel()
        switch handleTouch {
        case .repositioning:
            var edge: KyroNavigationEdge?
            if let dropped = dragLocation {
                let snapped = geometry.anchor(snapping: dropped)
                edge = snapped.edge
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.72)) {
                    store.preferences.setAnchor(snapped, for: style)
                    dragLocation = nil
                }
                snapTick += 1
            }
            isRepositioning = false
            store.lastHandleTrace = traceRecorder.finish(.moved, edge: edge)
        case .scrubbing:
            let index = KyroNavigationGeometry.index(at: location, in: centers, itemSize: itemSize)
            scrubIndex = nil
            isHandleScrubbing = false
            store.lastHandleTrace = traceRecorder.finish(.scrubbed)
            if isExpanded, let index, destinations.indices.contains(index) {
                select(destinations[index])
            }
        case .pending:
            // Lifted before moving or being picked up: the handle's tap.
            store.lastHandleTrace = traceRecorder.finish(.tap)
            registerTouchTap()
        case .ignored:
            store.lastHandleTrace = traceRecorder.finish(.ignored)
        case .idle:
            break
        }
        dragLocation = nil
        isDragArmed = false
        gestureStartTime = nil
        handleTouch = .idle
        noteActivity()
    }

    /// The system cancelled the touch (a call, Control Center), so onEnded never ran:
    /// a picked-up handle still snaps where it was, and nothing is chosen.
    private func cancelHandleTouch() {
        guard handleTouch != .idle else { return }
        pressTimer?.cancel()
        var edge: KyroNavigationEdge?
        if handleTouch == .repositioning, let dropped = dragLocation, bounds.width > 0 {
            let snapped = KyroNavigationGeometry(bounds: bounds).anchor(snapping: dropped)
            edge = snapped.edge
            store.preferences.setAnchor(snapped, for: style)
        }
        store.lastHandleTrace = traceRecorder.finish(.cancelled, edge: edge)
        handleTouch = .idle
        dragLocation = nil
        isDragArmed = false
        gestureStartTime = nil
        isRepositioning = false
        isHandleScrubbing = false
        scrubIndex = nil
    }

    /// Slide across the open destinations and lift to choose.
    private func scrubGesture(centers: [CGPoint], itemSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Self.scrubSlop, coordinateSpace: .named(Self.coordinateSpace))
            .onChanged { value in
                guard preferences.thumbScrubbing, !isRepositioning else { return }
                updateScrub(at: value.location, centers: centers, itemSize: itemSize)
            }
            .onEnded { value in
                defer { scrubIndex = nil }
                guard preferences.thumbScrubbing, !isRepositioning, isExpanded,
                      let index = KyroNavigationGeometry.index(at: value.location, in: centers, itemSize: itemSize),
                      destinations.indices.contains(index) else { return }
                select(destinations[index])
            }
    }

    private func beginRepositioning() {
        guard !isRepositioning, !isExpanded else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isRepositioning = true }
        isDragArmed = false
        isFaded = false
    }

    // MARK: State changes

    private func select(_ destination: KyroLiveTVDestination) {
        // A tap and a scrub ending on the same button must not navigate twice.
        guard Date().timeIntervalSince(lastSelection) > 0.35 else { return }
        lastSelection = Date()
        scrubIndex = nil
        selectionTick += 1
        if destination != active || destination == .search {
            navigate(destination)
        }
        if preferences.autoCollapse || !isExpanded {
            collapse()
        } else {
            noteActivity()
        }
    }

    private func move(to edge: KyroNavigationEdge) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.72)) {
            store.preferences.setAnchor(.default(for: edge), for: style)
        }
        snapTick += 1
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        noteActivity()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.78)) {
            store.isExpanded = expanded
        }
    }

    private func collapse() {
        scrubIndex = nil
        setExpanded(false)
    }

    private func noteActivity() {
        activity &+= 1
        if isFaded { withAnimation(.easeOut(duration: 0.2)) { isFaded = false } }
    }

    private struct IdleKey: Hashable {
        let expanded: Bool
        let faded: Bool
        let activity: Int
        let behavior: KyroLiveTVNavigationIdleBehavior
        let voiceOver: Bool
        let repositioning: Bool
    }

    /// VoiceOver users get all the time they need: nothing closes or fades on its own.
    private func runIdleTimer() async {
        guard !voiceOver, !isRepositioning, preferences.idleBehavior != .stayVisible else { return }
        if isExpanded {
            do { try await Task.sleep(for: Self.expandedIdleDelay) } catch { return }
            collapse()
        } else if preferences.idleBehavior == .collapseAndFade, !isFaded {
            do { try await Task.sleep(for: Self.fadeDelay) } catch { return }
            withAnimation(.easeInOut(duration: 0.6)) { isFaded = true }
        }
    }

    // MARK: Motion

    private func expandTransition(from point: CGPoint, in size: CGSize) -> AnyTransition {
        guard !reduceMotion, size.width > 0, size.height > 0 else { return .opacity }
        let anchor = UnitPoint(x: point.x / size.width, y: point.y / size.height)
        return .scale(scale: 0.35, anchor: anchor).combined(with: .opacity)
    }

    private func fanItemTransition(from origin: CGPoint, to center: CGPoint, index: Int) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .offset(x: origin.x - center.x, y: origin.y - center.y)
            .combined(with: .scale(scale: 0.3))
            .combined(with: .opacity)
            .animation(.spring(response: 0.36, dampingFraction: 0.74).delay(Double(index) * 0.025))
    }
}

/// A slight press-down for the destinations.
private struct KyroPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
