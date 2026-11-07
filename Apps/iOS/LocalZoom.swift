import CoreGraphics

/// Tells a two-finger scroll from a pinch. A pinch needs the spread to change by
/// `pinchSpread` and by more than the fingers moved together, since fingers drift
/// apart a little in a scroll. The first decision holds until the fingers lift.
struct TwoFingerGesture: Equatable {
    enum Kind: Equatable { case undecided, scroll, pinch }
    static let pinchSpread: CGFloat = 40
    static let slop: CGFloat = 10
    let startCentre: CGPoint
    let startSpread: CGFloat
    private(set) var kind: Kind

    init(_ first: CGPoint, _ second: CGPoint, allowsPinch: Bool = true) {
        startCentre = Self.centre(first, second)
        startSpread = Self.distance(first, second)
        kind = allowsPinch ? .undecided : .scroll
    }

    @discardableResult
    mutating func update(_ first: CGPoint, _ second: CGPoint) -> Kind {
        guard kind == .undecided else { return kind }
        let spreadBy = abs(Self.distance(first, second) - startSpread)
        let movedBy = Self.distance(Self.centre(first, second), startCentre)
        if spreadBy >= Self.pinchSpread && spreadBy > movedBy { kind = .pinch }
        else if movedBy > Self.slop && movedBy >= spreadBy { kind = .scroll }
        return kind
    }

    static func centre(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}

/// Local zoom of the Mac picture: nothing is sent to the Mac. A view point is
/// `content * scale + offset`, so touches map back through the same transform.
struct LocalZoom: Equatable {
    static let maximumScale: CGFloat = 6
    /// Pinching back to within this of 1× snaps to fit.
    static let snapScale: CGFloat = 1.05
    private struct Pinch: Equatable { var scale: CGFloat; var offset: CGPoint; var centre: CGPoint; var spread: CGFloat }
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGPoint.zero
    private var pinch: Pinch?
    /// The view the zoom was last placed in, so a new layout can carry it over.
    private var bounds: CGRect?

    var isZoomed: Bool { scale > 1 }

    /// The unzoomed view point drawn under `point`.
    func content(at point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    func normalized(_ point: CGPoint, in bounds: CGRect, aspect: Double, clamped: Bool = false) -> CGPoint? {
        DesktopTouchGeometry.normalized(content(at: point), in: bounds, aspect: aspect, clamped: clamped)
    }

    mutating func beginPinch(centre: CGPoint, spread: CGFloat) {
        pinch = Pinch(scale: scale, offset: offset, centre: centre, spread: max(spread, 1))
    }

    /// Zooms by the change in spread, keeping the content under the fingers and following the centre.
    mutating func pinch(centre: CGPoint, spread: CGFloat, in bounds: CGRect, aspect: Double) {
        guard let pinch, spread.isFinite, centre.x.isFinite, centre.y.isFinite else { return }
        var next = min(Self.maximumScale, max(1, pinch.scale * spread / pinch.spread))
        if next < Self.snapScale { next = 1 }
        let anchor = CGPoint(x: (pinch.centre.x - pinch.offset.x) / pinch.scale,
                             y: (pinch.centre.y - pinch.offset.y) / pinch.scale)
        scale = next
        offset = CGPoint(x: centre.x - anchor.x * next, y: centre.y - anchor.y * next)
        clamp(in: bounds, aspect: aspect)
        self.bounds = bounds
    }

    mutating func endPinch() { pinch = nil }

    /// Carries the zoom into the view's current bounds.
    mutating func layout(in bounds: CGRect, aspect: Double) {
        resize(from: self.bounds ?? bounds, to: bounds, aspect: aspect)
        self.bounds = bounds
    }

    /// The view changed size, say for the keyboard: keep the scale and the Mac point under the centre.
    mutating func resize(from old: CGRect, to new: CGRect, aspect: Double) {
        guard old != new else { return }
        pinch = nil
        guard isZoomed else { return }
        guard let mac = normalized(CGPoint(x: old.midX, y: old.midY), in: old, aspect: aspect, clamped: true),
              let image = DesktopTouchGeometry.imageRect(in: new, aspect: aspect) else { reset(); return }
        let content = CGPoint(x: image.minX + mac.x * image.width, y: image.minY + mac.y * image.height)
        offset = CGPoint(x: new.midX - content.x * scale, y: new.midY - content.y * scale)
        clamp(in: new, aspect: aspect)
    }

    mutating func reset() { self = LocalZoom() }

    /// Keeps the picture covering the view, or centred on an axis where it is smaller.
    private mutating func clamp(in bounds: CGRect, aspect: Double) {
        guard scale > 1, let image = DesktopTouchGeometry.imageRect(in: bounds, aspect: aspect) else {
            scale = 1; offset = .zero; return
        }
        func axis(_ offset: CGFloat, imageMin: CGFloat, imageLength: CGFloat, boundsMin: CGFloat, boundsLength: CGFloat) -> CGFloat {
            let length = imageLength * scale
            let start = imageMin * scale + offset
            let placed = length <= boundsLength ? boundsMin + (boundsLength - length) / 2
                : min(boundsMin, max(boundsMin + boundsLength - length, start))
            return placed - imageMin * scale
        }
        offset = CGPoint(x: axis(offset.x, imageMin: image.minX, imageLength: image.width, boundsMin: bounds.minX, boundsLength: bounds.width),
                         y: axis(offset.y, imageMin: image.minY, imageLength: image.height, boundsMin: bounds.minY, boundsLength: bounds.height))
    }
}
