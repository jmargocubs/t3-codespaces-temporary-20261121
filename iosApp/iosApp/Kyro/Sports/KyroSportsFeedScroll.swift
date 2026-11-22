import CoreGraphics
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

/// The Sports Feed's scroll position while Game, Stats or News is on top (Build 61).
///
/// The Feed stays mounted under the other tabs, so its scroll view normally keeps its offset. Two
/// things still moved it:
/// - A fling still coasting when another tab was tapped kept coasting behind that tab, so the
///   Feed came back wherever the momentum stopped. In the Build 60 recording the Feed was still
///   coasting toward the top when Game was selected (recording 323.1–324.0 s) and was at the top
///   on return.
/// - Anything that changes the hidden scroll view's offset while it cannot be seen.
///
/// The rule: leaving the Feed freezes it at the offset it had when the tab was tapped, and
/// returning puts that offset back if anything moved it. Changing the sport or the day replaces
/// the Feed's rows; that is done from the Feed itself, with its header in view, and keeps the
/// current offset as before, so nothing saved earlier is restored over new content.
struct KyroSportsFeedScrollMemory: Equatable {
    /// Offsets within this many points are treated as unchanged.
    static let tolerance: CGFloat = 1

    /// The Feed's offset when it was last hidden, kept until it is shown again.
    private(set) var saved: CGFloat?

    /// What the Feed's scroll view should do when the Feed is hidden or shown.
    enum Action: Equatable {
        /// Stop any momentum by setting the offset the Feed already has.
        case freeze(CGFloat)
        /// Put the Feed back where it was left.
        case restore(CGFloat)
    }

    /// The Feed was hidden (another tab is on top) or shown again. `offset` is its current
    /// content offset; `maximumOffset` the furthest it can scroll with its current content.
    mutating func visibilityChanged(isVisible: Bool, offset: CGFloat, maximumOffset: CGFloat) -> Action? {
        if !isVisible {
            // The first hide owns the offset. A second hide, or a scroll callback that arrives
            // after the tab switch, must not replace it with a later, coasted position.
            if let saved { return .freeze(saved) }
            saved = max(0, offset)
            return .freeze(max(0, offset))
        }
        guard let saved else { return nil }
        self.saved = nil
        let target = min(saved, max(0, maximumOffset))
        guard abs(target - offset) > Self.tolerance else { return nil }
        return .restore(target)
    }

    /// New rows replaced the Feed's content (another sport or day). A saved offset belongs to the
    /// old rows, so it is dropped.
    mutating func contentReplaced() {
        saved = nil
    }
}

/// The Feed's live scroll geometry, written while scrolling without invalidating any view.
final class KyroSportsFeedScrollTracker {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// Unbounded until the Feed has reported its content, so an early read never clamps to zero.
    var maximumOffset: CGFloat {
        contentHeight > 0 ? max(0, contentHeight - viewportHeight) : .greatestFiniteMagnitude
    }
}

/// The geometry the Feed reports, in the same coordinates `ScrollPosition.scrollTo(y:)` takes:
/// content y at the top of the area below the player and tab bar.
struct KyroSportsFeedScrollGeometry: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

/// What the Feed's scroll view exposes to the coordinator. The real one reads and writes the
/// UIScrollView directly, so a read is the offset at that instant, never a delayed SwiftUI report.
protocol KyroSportsFeedScrollDriving: AnyObject {
    var offset: CGFloat { get }
    var maximumOffset: CGFloat { get }
    /// Jump to `offset` without animation. This also ends any momentum.
    func setOffset(_ offset: CGFloat)
}

/// Applies `KyroSportsFeedScrollMemory` to the Feed's scroll view.
///
/// Build 62: Build 61 froze and restored the Feed from `onChange(of: isFeedVisible)`, which runs
/// after the tab change has rendered, from an offset SwiftUI had reported earlier, through
/// `ScrollPosition.scrollTo`, which may not stop a fling that SwiftUI believes is already at that
/// value. Device test: tapping Game mid-flick still returned to a coasted position. Now the offset
/// is read from the scroll view and frozen in the same call as the tap, and set back the same way.
final class KyroSportsFeedScrollCoordinator {
    private(set) var memory = KyroSportsFeedScrollMemory()
    var driver: (any KyroSportsFeedScrollDriving)?

    /// The offset that will be restored, if the Feed is currently covered.
    var savedOffset: CGFloat? { memory.saved }

    /// Another tab is taking over. Safe to call more than once; the first call keeps the offset.
    func feedHidden() {
        guard let driver else { return }
        apply(memory.visibilityChanged(isVisible: false, offset: driver.offset, maximumOffset: driver.maximumOffset))
    }

    /// The Feed is on top again.
    func feedShown() {
        guard let driver else { return }
        apply(memory.visibilityChanged(isVisible: true, offset: driver.offset, maximumOffset: driver.maximumOffset))
    }

    /// New rows replaced the Feed's content, so a saved offset no longer applies.
    func contentReplaced() {
        memory.contentReplaced()
    }

    private func apply(_ action: KyroSportsFeedScrollMemory.Action?) {
        switch action {
        case .freeze(let offset), .restore(let offset): driver?.setOffset(offset)
        case nil: break
        }
    }
}

/// The Feed's scroll driver: the UIScrollView when it has been found, otherwise the SwiftUI
/// scroll position with the last reported geometry.
final class KyroSportsFeedScrollDriver: KyroSportsFeedScrollDriving {
    let tracker = KyroSportsFeedScrollTracker()
    /// Used only when the UIScrollView could not be found.
    var scrollToFallback: ((CGFloat) -> Void)?
    #if canImport(UIKit)
    weak var scrollView: UIScrollView?
    #endif

    var offset: CGFloat {
        #if canImport(UIKit)
        if let scrollView { return scrollView.contentOffset.y + scrollView.adjustedContentInset.top }
        #endif
        return tracker.offset
    }

    var maximumOffset: CGFloat {
        #if canImport(UIKit)
        if let scrollView {
            let bottom = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            return max(0, bottom + scrollView.adjustedContentInset.top)
        }
        #endif
        return tracker.maximumOffset
    }

    func setOffset(_ offset: CGFloat) {
        #if canImport(UIKit)
        if let scrollView {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
                                                y: offset - scrollView.adjustedContentInset.top), animated: false)
            return
        }
        #endif
        scrollToFallback?(offset)
    }
}

#if canImport(UIKit)
/// Finds the Feed's UIScrollView from inside its content and hands it to the driver.
struct KyroSportsFeedScrollResolver: UIViewRepresentable {
    let driver: KyroSportsFeedScrollDriver

    func makeUIView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.driver = driver
        return view
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.driver = driver
        uiView.resolve()
    }

    final class ResolverView: UIView {
        weak var driver: KyroSportsFeedScrollDriver?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        func resolve() {
            guard let driver, driver.scrollView == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    driver.scrollView = scrollView
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
