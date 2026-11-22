import SwiftUI

/// The transport control a Live TV player shows for the session's state. Pause only while there is
/// something to pause; play only when paused. Connecting and failed show none, so a failure never
/// looks like active playback. Shared by the full-screen player and both inline players.
enum LiveTVTransportControl: Equatable {
    case pause
    case resume

    init?(state: LiveTVPlaybackState) {
        switch state {
        case .playing, .buffering: self = .pause
        case .paused: self = .resume
        case .connecting, .failed, .stopped: return nil
        }
    }

    var symbol: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pause: "Pause live stream"
        case .resume: "Resume live stream"
        }
    }
}

/// Sizes shared by the two inline players (the iPhone watch screen and Sports Hub), so their
/// controls match: small glass circles at the corners and one transport control in the middle,
/// with nothing written over the picture.
enum LiveTVInlineChromeMetrics {
    static let cornerButton: CGFloat = 34
    static let transportButton: CGFloat = 46
    static let edgeInset: CGFloat = 8
    static let pillHeight: CGFloat = 32
}

/// Moves the stream between an inline player and the full-screen player without the cover's
/// slide. Entering and leaving full screen rotates the screen; a cover that also slides while the
/// screen turns shows the player sideways and the screen underneath in the wrong orientation.
/// With the slide off, the cover swaps in one frame and the rotation is the only motion.
enum LiveTVCoverTransition {
    static func immediate(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

#if os(iOS)
/// A small glass circle for a corner of an inline player.
struct LiveTVInlineIconButton: View {
    let symbol: String
    let label: String
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .frame(width: LiveTVInlineChromeMetrics.cornerButton, height: LiveTVInlineChromeMetrics.cornerButton)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                // The visible circle is 34 points; the hit area meets the 44-point minimum.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? label)
    }
}

/// The inline players' corner and centre controls over the video. The caller supplies its own
/// leading and trailing buttons; the transport control and gradient scrims are common.
struct LiveTVInlineControlsOverlay<Leading: View, Trailing: View>: View {
    let transport: LiveTVTransportControl?
    let onTransport: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            // A light scrim at the top only, so the corner buttons read on bright pictures.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    leading()
                    Spacer(minLength: 0)
                    trailing()
                }
                .padding(.horizontal, LiveTVInlineChromeMetrics.edgeInset - 5)
                .padding(.top, LiveTVInlineChromeMetrics.edgeInset - 5)
                Spacer(minLength: 0)
            }
            if let transport {
                Button(action: onTransport) {
                    Image(systemName: transport.symbol)
                        .font(.title3.weight(.bold))
                        .frame(width: LiveTVInlineChromeMetrics.transportButton,
                               height: LiveTVInlineChromeMetrics.transportButton)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(transport.accessibilityLabel)
                .accessibilityHint("Temporary live-stream pause; the provider may not retain paused video.")
            }
        }
    }
}

/// Connecting, buffering and failure status for an inline player, in one compact glass panel.
struct LiveTVInlineStatusOverlay<Actions: View>: View {
    let state: LiveTVPlaybackState
    let errorMessage: String?
    @ViewBuilder let failureActions: () -> Actions

    var body: some View {
        switch state {
        case .connecting:
            panel { ProgressView("Connecting…").tint(.white).font(.footnote) }
        case .buffering:
            panel { ProgressView("Buffering…").tint(.white).font(.footnote) }
        case .failed:
            panel {
                VStack(spacing: 8) {
                    Text(errorMessage ?? LiveTVPlaybackFailure.unknown.message)
                        .font(.footnote).multilineTextAlignment(.center).lineLimit(3)
                    HStack(spacing: 8) { failureActions() }
                        .controlSize(.small)
                }
            }
        case .playing, .paused, .stopped:
            EmptyView()
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 24)
    }
}

/// A compact capsule action for the information area below an inline player.
struct LiveTVInlinePillButton: View {
    let title: String
    let symbol: String
    var tint: Color = Color.siloOnSurface
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.siloOnSurface)
            .padding(.horizontal, 12)
            .frame(height: LiveTVInlineChromeMetrics.pillHeight)
            .background(LiveTVSurface.row, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? title)
    }
}
#endif
