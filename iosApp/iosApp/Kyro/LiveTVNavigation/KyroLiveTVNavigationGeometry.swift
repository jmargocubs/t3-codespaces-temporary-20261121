import CoreGraphics
import Foundation

/// Where the floating navigation may sit, and how each style lays out
/// around the handle. Pure arithmetic over the overlay's safe-area bounds,
/// so it recomputes whenever the screen or its safe areas change and every
/// rule can be tested without a view.
///
/// `bounds` is already inside the safe area (the navigation bar, Dynamic
/// Island and home indicator are outside it); `margin` keeps the controls
/// clear of the screen's rounded corners and edge gestures.
struct KyroNavigationGeometry: Equatable {
    static let handleDiameter: CGFloat = 56
    /// Every destination keeps at least this square as its touch target.
    static let itemSize: CGFloat = 52
    static let margin: CGFloat = 12
    static let dockSpacing: CGFloat = 4
    static let dockPadding: CGFloat = 6
    /// The gap the fan keeps between neighbouring touch targets.
    static let fanGap: CGFloat = 10

    let bounds: CGRect

    /// The rectangle the handle's centre travels on. Its edges are the snap lines.
    var track: CGRect {
        let inset = Self.margin + Self.handleDiameter / 2
        return Self.inset(bounds, by: inset)
    }

    // MARK: Handle

    func center(for anchor: KyroNavigationAnchor) -> CGPoint {
        let track = track
        let t = CGFloat(anchor.position)
        switch anchor.edge {
        case .left: return CGPoint(x: track.minX, y: track.minY + t * track.height)
        case .right: return CGPoint(x: track.maxX, y: track.minY + t * track.height)
        case .top: return CGPoint(x: track.minX + t * track.width, y: track.minY)
        case .bottom: return CGPoint(x: track.minX + t * track.width, y: track.maxY)
        }
    }

    /// Keeps a dragged handle fully on screen.
    func clamped(_ point: CGPoint) -> CGPoint {
        let track = track
        return CGPoint(x: min(max(point.x, track.minX), track.maxX), y: min(max(point.y, track.minY), track.maxY))
    }

    /// The nearest edge to a released handle, keeping its place along that edge.
    /// Ties go to the side edges, which sit under the thumb.
    func anchor(snapping point: CGPoint) -> KyroNavigationAnchor {
        let track = track
        let p = clamped(point)
        let distances: [(KyroNavigationEdge, CGFloat)] = [
            (.right, track.maxX - p.x), (.left, p.x - track.minX),
            (.bottom, track.maxY - p.y), (.top, p.y - track.minY)
        ]
        let edge = distances.min { $0.1 < $1.1 }?.0 ?? .right
        let position: CGFloat
        if edge.isVertical {
            position = track.height > 0 ? (p.y - track.minY) / track.height : 0.5
        } else {
            position = track.width > 0 ? (p.x - track.minX) / track.width : 0.5
        }
        return KyroNavigationAnchor(edge: edge, position: Double(position))
    }

    // MARK: Adaptive Glass Dock

    struct DockLayout: Equatable {
        let isVertical: Bool
        let frame: CGRect
        /// Touch-target centres in overlay coordinates, in destination order.
        let itemCenters: [CGPoint]
        let itemSize: CGFloat
    }

    /// A rail on the left and right edges, a bar on the top and bottom. The dock
    /// hugs its edge, centres on the handle and slides inward at the corners.
    func dockLayout(for anchor: KyroNavigationAnchor, itemCount: Int) -> DockLayout {
        let count = max(itemCount, 1)
        let vertical = anchor.edge.isVertical
        let usable = Self.inset(bounds, by: Self.margin)
        let available = vertical ? usable.height : usable.width
        // Only a very short screen shrinks the targets; they never go below 44pt.
        let naturalLength = CGFloat(count) * Self.itemSize + CGFloat(count - 1) * Self.dockSpacing + 2 * Self.dockPadding
        let scale = naturalLength > available ? max(available / naturalLength, 44 / Self.itemSize) : 1
        let item = Self.itemSize * scale
        let spacing = Self.dockSpacing * scale
        let length = CGFloat(count) * item + CGFloat(count - 1) * spacing + 2 * Self.dockPadding
        let thickness = item + 2 * Self.dockPadding

        let handle = center(for: anchor)
        let size = vertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
        var origin = CGPoint(x: handle.x - size.width / 2, y: handle.y - size.height / 2)
        switch anchor.edge {
        case .left: origin.x = usable.minX
        case .right: origin.x = usable.maxX - size.width
        case .top: origin.y = usable.minY
        case .bottom: origin.y = usable.maxY - size.height
        }
        origin.x = Self.clamp(origin.x, usable.minX, usable.maxX - size.width)
        origin.y = Self.clamp(origin.y, usable.minY, usable.maxY - size.height)
        let frame = CGRect(origin: origin, size: size)

        let centers = (0..<count).map { index -> CGPoint in
            let along = Self.dockPadding + item / 2 + CGFloat(index) * (item + spacing)
            return vertical ? CGPoint(x: frame.midX, y: frame.minY + along)
                            : CGPoint(x: frame.minX + along, y: frame.midY)
        }
        return DockLayout(isVertical: vertical, frame: frame, itemCenters: centers, itemSize: item)
    }

    // MARK: Thumb Fan

    struct FanLayout: Equatable {
        /// The arc's centre. It is the handle unless the arc had to move inward to fit.
        let origin: CGPoint
        let radius: CGFloat
        /// Touch-target centres in overlay coordinates, in destination order.
        let itemCenters: [CGPoint]
    }

    /// Destinations on an arc that opens away from the handle's edge. In a corner
    /// the arc narrows to the quarter that faces inward, with a longer radius so
    /// neighbours never touch; when even that cannot fit, the arc moves inward.
    /// Items read top to bottom on side edges and left to right on top and bottom.
    func fanLayout(for anchor: KyroNavigationAnchor, itemCount: Int) -> FanLayout {
        let count = max(itemCount, 1)
        let handle = center(for: anchor)
        let allowed = Self.inset(bounds, by: Self.margin + Self.itemSize / 2)
        let normal = Self.inwardAngle(anchor.edge)

        // Half circle (150°) facing straight in, then quarter arcs (90°) turned
        // toward whichever neighbouring edge has more room.
        let wide = Self.arc(count: count, span: .pi * 150 / 180)
        let narrow = Self.arc(count: count, span: .pi / 2)
        let toward = cornerTurn(edge: anchor.edge, handle: handle)
        let candidates: [(center: CGFloat, arc: (span: CGFloat, radius: CGFloat))] = [
            (normal, wide),
            (normal + toward * .pi / 4, narrow),
            (normal - toward * .pi / 4, narrow)
        ]
        for candidate in candidates {
            let points = Self.points(origin: handle, center: candidate.center, span: candidate.arc.span,
                                     radius: candidate.arc.radius, count: count)
            if points.allSatisfy({ allowed.insetBy(dx: -0.5, dy: -0.5).contains($0) }) {
                return FanLayout(origin: handle, radius: candidate.arc.radius,
                                 itemCenters: ordered(points, edge: anchor.edge))
            }
        }

        // Nothing fits around the handle itself (a short landscape screen): move
        // the inward-facing quarter arc just far enough to fit, then clamp.
        let center = normal + toward * .pi / 4
        let raw = Self.points(origin: handle, center: center, span: narrow.span, radius: narrow.radius, count: count)
        let shift = Self.shiftToFit(raw, in: allowed)
        let origin = CGPoint(x: handle.x + shift.x, y: handle.y + shift.y)
        let fitted = raw.map { CGPoint(x: Self.clamp($0.x + shift.x, allowed.minX, allowed.maxX),
                                       y: Self.clamp($0.y + shift.y, allowed.minY, allowed.maxY)) }
        return FanLayout(origin: origin, radius: narrow.radius, itemCenters: ordered(fitted, edge: anchor.edge))
    }

    /// +1 turns the arc clockwise from the inward normal (in screen space), −1 the other way;
    /// the arc turns away from the nearer perpendicular edge.
    private func cornerTurn(edge: KyroNavigationEdge, handle: CGPoint) -> CGFloat {
        let track = track
        switch edge {
        case .left:
            // Normal points right; clockwise turns it downward.
            return handle.y - track.minY < track.maxY - handle.y ? 1 : -1
        case .right:
            // Normal points left; clockwise turns it upward.
            return handle.y - track.minY < track.maxY - handle.y ? -1 : 1
        case .top:
            // Normal points down; clockwise turns it left.
            return handle.x - track.minX < track.maxX - handle.x ? -1 : 1
        case .bottom:
            // Normal points up; clockwise turns it right.
            return handle.x - track.minX < track.maxX - handle.x ? 1 : -1
        }
    }

    private func ordered(_ points: [CGPoint], edge: KyroNavigationEdge) -> [CGPoint] {
        edge.isVertical ? points.sorted { $0.y < $1.y } : points.sorted { $0.x < $1.x }
    }

    /// The radius that keeps neighbouring targets `fanGap` apart for this span.
    private static func arc(count: Int, span: CGFloat) -> (span: CGFloat, radius: CGFloat) {
        guard count > 1 else { return (0, itemSize + fanGap + handleDiameter / 2) }
        let step = span / CGFloat(count - 1)
        let chord = itemSize + fanGap
        let radius = max(chord / (2 * sin(step / 2)), handleDiameter / 2 + itemSize / 2 + fanGap)
        return (span, radius.rounded(.up))
    }

    /// Screen angles (y grows downward): 0 points right, π/2 down.
    private static func inwardAngle(_ edge: KyroNavigationEdge) -> CGFloat {
        switch edge {
        case .left: 0
        case .right: .pi
        case .top: .pi / 2
        case .bottom: -.pi / 2
        }
    }

    private static func points(origin: CGPoint, center: CGFloat, span: CGFloat, radius: CGFloat,
                               count: Int) -> [CGPoint] {
        guard count > 1 else {
            return [CGPoint(x: origin.x + radius * cos(center), y: origin.y + radius * sin(center))]
        }
        let start = center - span / 2
        let step = span / CGFloat(count - 1)
        return (0..<count).map { index in
            let angle = start + CGFloat(index) * step
            return CGPoint(x: origin.x + radius * cos(angle), y: origin.y + radius * sin(angle))
        }
    }

    private static func shiftToFit(_ points: [CGPoint], in rect: CGRect) -> CGPoint {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return .zero }
        func shift(_ low: CGFloat, _ high: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if low < lower { return lower - low }
            if high > upper { return upper - high }
            return 0
        }
        return CGPoint(x: shift(minX, maxX, rect.minX, rect.maxX), y: shift(minY, maxY, rect.minY, rect.maxY))
    }

    private static func inset(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        let dx = min(amount, rect.width / 2)
        let dy = min(amount, rect.height / 2)
        return rect.insetBy(dx: dx, dy: dy)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        upper < lower ? (lower + upper) / 2 : min(max(value, lower), upper)
    }
}

extension KyroNavigationGeometry {
    /// The destination under a finger during thumb scrubbing, if any.
    static func index(at point: CGPoint, in centers: [CGPoint], itemSize: CGFloat,
                      tolerance: CGFloat = 10) -> Int? {
        let reach = itemSize / 2 + tolerance
        let nearest = centers.enumerated().min { hypot($0.element.x - point.x, $0.element.y - point.y)
            < hypot($1.element.x - point.x, $1.element.y - point.y) }
        guard let nearest, hypot(nearest.element.x - point.x, nearest.element.y - point.y) <= reach * 1.42 else {
            return nil
        }
        return nearest.offset
    }
}
