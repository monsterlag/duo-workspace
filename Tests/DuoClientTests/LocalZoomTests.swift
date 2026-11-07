import CoreGraphics
import Testing
@testable import DuoWorkspace

struct LocalZoomTests {
    @Test func scrollWithDriftingSpreadStaysScroll() {
        var gesture = TwoFingerGesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        #expect(gesture.update(CGPoint(x: 100, y: 105), CGPoint(x: 230, y: 105)) == .undecided)
        #expect(gesture.update(CGPoint(x: 100, y: 160), CGPoint(x: 230, y: 160)) == .scroll)
        #expect(gesture.update(CGPoint(x: 60, y: 160), CGPoint(x: 290, y: 160)) == .scroll)
    }

    @Test func spreadChangeWithLittleCommonMovementBecomesPinch() {
        var gesture = TwoFingerGesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        #expect(gesture.update(CGPoint(x: 78, y: 102), CGPoint(x: 223, y: 102)) == .pinch)
        #expect(gesture.update(CGPoint(x: 120, y: 300), CGPoint(x: 220, y: 300)) == .pinch)
        var scroll = TwoFingerGesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), allowsPinch: false)
        #expect(scroll.update(CGPoint(x: 50, y: 100), CGPoint(x: 250, y: 100)) == .scroll)
    }

    @Test func zoomClampsAndSnapsToFit() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        var zoom = LocalZoom()
        zoom.beginPinch(centre: CGPoint(x: 200, y: 200), spread: 50)
        zoom.pinch(centre: CGPoint(x: 200, y: 200), spread: 1000, in: bounds, aspect: 2)
        #expect(zoom.scale == LocalZoom.maximumScale)
        zoom.pinch(centre: CGPoint(x: 200, y: 200), spread: 52, in: bounds, aspect: 2)
        #expect(zoom.scale == 1 && zoom.offset == .zero)
        zoom.pinch(centre: CGPoint(x: 200, y: 200), spread: 20, in: bounds, aspect: 2)
        #expect(zoom.scale == 1 && zoom.offset == .zero && !zoom.isZoomed)
        zoom.endPinch()
    }

    @Test func pointsMapThroughZoomAndPanToMacCoordinates() throws {
        // A 2:1 picture letterboxed in a square view: drawn at y 100…300 when fit.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        var zoom = LocalZoom()
        #expect(zoom.normalized(CGPoint(x: 200, y: 50), in: bounds, aspect: 2) == nil)
        zoom.beginPinch(centre: CGPoint(x: 100, y: 200), spread: 50)
        zoom.pinch(centre: CGPoint(x: 100, y: 200), spread: 150, in: bounds, aspect: 2)
        #expect(zoom.scale == 3)
        // The pan is clamped so the picture still covers the view vertically.
        #expect(zoom.offset == CGPoint(x: -200, y: -400))
        let underFingers = try #require(zoom.normalized(CGPoint(x: 100, y: 200), in: bounds, aspect: 2))
        #expect(abs(underFingers.x - 0.25) < 0.0001 && abs(underFingers.y - 0.5) < 0.0001)
        let corner = try #require(zoom.normalized(.zero, in: bounds, aspect: 2))
        #expect(abs(corner.x - 1.0 / 6) < 0.0001 && abs(corner.y - 1.0 / 6) < 0.0001)
        zoom.reset()
        #expect(zoom.normalized(CGPoint(x: 200, y: 50), in: bounds, aspect: 2) == nil)
    }

    @Test func resizeKeepsTheMacPointUnderTheCentre() throws {
        let tall = CGRect(x: 0, y: 0, width: 400, height: 400), short = CGRect(x: 0, y: 0, width: 400, height: 250)
        var zoom = LocalZoom()
        zoom.layout(in: tall, aspect: 2)
        zoom.beginPinch(centre: CGPoint(x: 100, y: 200), spread: 50)
        zoom.pinch(centre: CGPoint(x: 100, y: 200), spread: 150, in: tall, aspect: 2)
        let before = try #require(zoom.normalized(CGPoint(x: tall.midX, y: tall.midY), in: tall, aspect: 2))
        zoom.layout(in: short, aspect: 2)
        #expect(zoom.scale == 3)
        let after = try #require(zoom.normalized(CGPoint(x: short.midX, y: short.midY), in: short, aspect: 2))
        #expect(abs(after.x - before.x) < 0.0001 && abs(after.y - before.y) < 0.0001)
    }
}
