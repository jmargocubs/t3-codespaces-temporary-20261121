import CoreGraphics
import Foundation

/// What the last touch on the navigation handle did, measured from the
/// handle's rendered frame rather than the saved position. Live TV Settings →
/// Navigation shows it, so a device that misbehaves gives evidence instead
/// of a guess, and the UI tests read it to prove the handle followed the
/// finger before it snapped.
struct KyroNavigationHandleTrace: Equatable, Sendable {
    enum Outcome: String, Sendable {
        case tap, moved, scrubbed, cancelled, ignored
    }

    enum PickUp: String, Sendable {
        /// Movement began after the stationary hold armed dragging.
        case hold
        /// The first movement after the hold arrived before the timer ran.
        case movement
    }

    var touchUpdates = 0
    var armedAfter: TimeInterval?
    var pickUp: PickUp?
    var pickUpDelay: TimeInterval?
    /// Rendered handle frames laid out while it was picked up.
    var renderedMoves = 0
    /// The farthest the rendered handle got from where it was picked up.
    var renderedTravel: CGFloat = 0
    /// The largest gap between the rendered handle and the finger, after the
    /// first frame that followed it.
    var maxLag: CGFloat = 0
    var outcome: Outcome?
    var snappedEdge: KyroNavigationEdge?

    /// One line for Settings and the UI tests.
    var summary: String {
        var parts = ["\(outcome?.rawValue ?? "touching")", "updates \(touchUpdates)"]
        if let armedAfter {
            parts.append("armed after \(Int((armedAfter * 1000).rounded())) ms")
        }
        if let pickUp, let pickUpDelay {
            parts.append("picked up by \(pickUp.rawValue) after \(Int((pickUpDelay * 1000).rounded())) ms")
        }
        if pickUp != nil {
            parts.append("rendered \(renderedMoves) frames")
            parts.append("travel \(Int(renderedTravel.rounded())) pt")
            parts.append("lag \(Int(maxLag.rounded())) pt")
        }
        if let snappedEdge { parts.append("snapped \(snappedEdge.rawValue)") }
        return parts.joined(separator: " · ")
    }
}

/// Collects a trace without invalidating the view on every frame.
@MainActor
final class KyroNavigationHandleTraceRecorder {
    private(set) var trace = KyroNavigationHandleTrace()
    private var origin: CGPoint?

    func begin() {
        trace = KyroNavigationHandleTrace()
        origin = nil
    }

    func noteUpdate() { trace.touchUpdates += 1 }

    func noteArmed(after delay: TimeInterval) {
        trace.armedAfter = max(delay, 0)
    }

    func notePickUp(_ pickUp: KyroNavigationHandleTrace.PickUp, after delay: TimeInterval, at center: CGPoint) {
        guard trace.pickUp == nil else { return }
        trace.pickUp = pickUp
        trace.pickUpDelay = max(delay, 0)
        origin = center
    }

    /// A rendered handle centre while it is picked up, and where the finger is.
    func noteRendered(_ center: CGPoint, finger: CGPoint?) {
        guard let origin else { return }
        trace.renderedMoves += 1
        trace.renderedTravel = max(trace.renderedTravel, hypot(center.x - origin.x, center.y - origin.y))
        if let finger {
            trace.maxLag = max(trace.maxLag, hypot(center.x - finger.x, center.y - finger.y))
        }
    }

    func finish(_ outcome: KyroNavigationHandleTrace.Outcome, edge: KyroNavigationEdge? = nil) -> KyroNavigationHandleTrace {
        trace.outcome = outcome
        trace.snappedEdge = edge
        origin = nil
        return trace
    }
}
