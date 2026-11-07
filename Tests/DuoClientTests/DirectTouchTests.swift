import UIKit
import Testing
import DuoCore
@testable import DuoWorkspace

@MainActor
struct DirectTouchTests {
    @Test func trackpadPreservesMovementBeforeGestureRecognition() throws {
        try withInput { _, _, control, view, events in
            let gesture = TestPanGesture()
            view.addGestureRecognizer(gesture)
            gesture.reportedLocation = CGPoint(x: 200, y: 200)
            gesture.reportedTranslation = CGPoint(x: 100, y: 0)
            #expect(control.preparePan(gesture))
            gesture.reportedTranslation = .zero
            gesture.reportedState = .began
            control.pan(gesture)
            #expect(events.value.last?.x == 0.75)
            gesture.reportedState = .ended
            control.pan(gesture)
            #expect(events.value.last?.x == 0.75)
        }
    }
    @Test func quickEdgeSwipeRestoresControlsWhenUIKitResetsTranslation() throws {
        try withInput { _, _, control, view, events in
            var reveals = 0
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick,
                              revealControls: { reveals += 1 })
            let gesture = TestPanGesture()
            view.addGestureRecognizer(gesture)
            for (start, end) in [(20.0, 200.0), (380.0, 200.0)] {
                gesture.reportedLocation = CGPoint(x: end, y: 200)
                gesture.reportedTranslation = CGPoint(x: end - start, y: 0)
                #expect(control.prepareReveal(gesture))
                gesture.reportedTranslation = .zero
                gesture.reportedState = .began
                control.reveal(gesture)
                gesture.reportedState = .ended
                control.reveal(gesture)
            }
            #expect(reveals == 2)
            #expect(events.value.allSatisfy { $0.kind == .releaseAll })
        }
    }

    @Test func directPanUsesOriginalTouchAfterRecognitionResetsTranslation() throws {
        try withInput { _, input, control, view, events in
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick, revealControls: nil)
            let gesture = TestPanGesture()
            view.addGestureRecognizer(gesture)
            gesture.reportedLocation = CGPoint(x: 100, y: 390)
            gesture.reportedTranslation = CGPoint(x: 0, y: 240)
            #expect(control.preparePan(gesture))
            gesture.reportedTranslation = .zero
            gesture.reportedState = .began
            control.pan(gesture)
            #expect(events.value.last?.kind == .move && events.value.last?.y == 1)
            gesture.reportedState = .ended
            control.pan(gesture)

            input.toggleScroll()
            gesture.reportedLocation = CGPoint(x: 100, y: 200)
            gesture.reportedTranslation = CGPoint(x: 0, y: 50)
            #expect(control.preparePan(gesture, scrolling: true))
            gesture.reportedTranslation = .zero
            gesture.reportedState = .began
            events.value.removeAll()
            control.scroll(gesture)
            #expect(events.value.first?.x == 0.25 && events.value.first?.y == 0.25)
            #expect(events.value.last?.kind == .scroll && events.value.last?.y == 50)

            gesture.reportedLocation = CGPoint(x: 100, y: 200)
            gesture.reportedTranslation = CGPoint(x: 0, y: 180)
            #expect(!control.preparePan(gesture))
            #expect(control.preparePan(gesture, scrolling: true))
        }
    }
    @Test func revealUsesLocalEdgesAndRequiresAnInwardHorizontalSwipe() {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 600)
        let left = CGPoint(x: 15, y: 200), right = CGPoint(x: 400, y: 200)
        #expect(ControlsRevealGesture.isInward(start: left, translation: CGPoint(x: 40, y: 2), in: bounds, minimumDistance: 32))
        #expect(ControlsRevealGesture.isInward(start: right, translation: CGPoint(x: -40, y: 2), in: bounds, minimumDistance: 32))
        #expect(!ControlsRevealGesture.isInward(start: left, translation: CGPoint(x: -40, y: 2), in: bounds))
        #expect(!ControlsRevealGesture.isInward(start: right, translation: CGPoint(x: 40, y: 2), in: bounds))
        #expect(!ControlsRevealGesture.isInward(start: left, translation: CGPoint(x: 10, y: 60), in: bounds))
        #expect(!ControlsRevealGesture.isInward(start: left, translation: CGPoint(x: 25, y: 2), in: bounds, minimumDistance: 32))
        #expect(!ControlsRevealGesture.isInward(start: CGPoint(x: 200, y: 200), translation: CGPoint(x: 80, y: 2), in: bounds))
        #expect(!ControlsRevealGesture.startsAtEdge(CGPoint(x: 0, y: 200), in: bounds))
    }
    @Test func coordinatesFollowCenteredVideoAcrossWorkspaceShapes() throws {
        for size in [CGSize(width: 466, height: 678), CGSize(width: 669, height: 951),
                     CGSize(width: 951, height: 669), CGSize(width: 669, height: 440)] {
            for aspect in [16.0 / 9, 1.6, 0.75, 1] {
                let bounds = CGRect(origin: CGPoint(x: 5, y: 9), size: size)
                let image = try #require(DesktopTouchGeometry.imageRect(in: bounds, aspect: aspect))
                #expect(abs(image.midX - bounds.midX) < 0.0001)
                #expect(abs(image.midY - bounds.midY) < 0.0001)
                let point = CGPoint(x: image.minX + image.width * 0.25, y: image.minY + image.height * 0.75)
                let mapped = try #require(DesktopTouchGeometry.normalized(point, in: bounds, aspect: aspect))
                #expect(abs(mapped.x - 0.25) < 0.0001)
                #expect(abs(mapped.y - 0.75) < 0.0001)
            }
        }
    }

    @Test func marginsAndInvalidGeometryCannotBecomeClicks() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(DesktopTouchGeometry.normalized(CGPoint(x: 200, y: 10), in: bounds, aspect: 2) == nil)
        #expect(DesktopTouchGeometry.normalized(CGPoint(x: 200, y: 390), in: bounds, aspect: 2) == nil)
        #expect(DesktopTouchGeometry.normalized(CGPoint(x: 10, y: 200), in: bounds, aspect: 0.5) == nil)
        #expect(DesktopTouchGeometry.normalized(CGPoint(x: CGFloat.nan, y: 100), in: bounds, aspect: 1) == nil)
        #expect(DesktopTouchGeometry.imageRect(in: .zero, aspect: 1) == nil)
        #expect(DesktopTouchGeometry.imageRect(in: bounds, aspect: .infinity) == nil)
        #expect(DesktopTouchGeometry.normalized(CGPoint(x: 900, y: -10), in: bounds, aspect: 2, clamped: true) == CGPoint(x: 1, y: 0))
    }

    @Test func touchClickMovesBeforePressAndIgnoresTrackpadSpeed() throws {
        try withInput { settings, input, control, view, events in
            settings.pointerSpeed = 2
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick, revealControls: nil)
            events.value.removeAll()
            control.click(at: CGPoint(x: 100, y: 150), in: view.bounds, time: 10)
            #expect(events.value.map(\.kind) == [.move, .leftDown, .leftUp])
            #expect(events.value.allSatisfy { $0.x == 0.25 && $0.y == 0.25 })
            events.value.removeAll()
            control.click(at: CGPoint(x: 200, y: 20), in: view.bounds, time: 20)
            #expect(events.value.isEmpty)
            control.click(at: CGPoint(x: 300, y: 250), in: view.bounds, time: 30)
            #expect(events.value.last?.x == 0.75 && events.value.last?.y == 0.75)
        }
    }

    @Test func rightClickRepositionsAndReleasesOneShotModifier() throws {
        try withInput { _, input, control, view, events in
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick, revealControls: nil)
            input.modifier(.shift)
            events.value.removeAll()
            control.rightClick(at: CGPoint(x: 100, y: 250), in: view.bounds)
            #expect(events.value.map(\.kind) == [.move, .rightClick, .keyUp])
            #expect(events.value[1].x == 0.25 && events.value[1].y == 0.75)
            #expect(input.modifiers.isEmpty)
        }
    }

    @Test func ordinaryDoubleClickKeepsBothClicksAtSameMacPosition() throws {
        try withInput { _, _, control, view, events in
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .doubleClick, revealControls: nil)
            events.value.removeAll()
            control.click(at: CGPoint(x: 100, y: 150), in: view.bounds, time: 10)
            control.click(at: CGPoint(x: 106, y: 155), in: view.bounds, time: 10.2)
            let presses = events.value.filter { $0.kind == .leftDown }
            #expect(presses.map(\.clickCount) == [1, 2])
            #expect(presses.allSatisfy { $0.x == 0.25 && $0.y == 0.25 })
            #expect(!events.value.contains { $0.kind == .rightClick })
        }
    }

    @Test func directDragClampsAtImageEdgeAndCancellationReleasesButton() throws {
        try withInput { _, input, control, view, events in
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick, revealControls: nil)
            let pan = TestPanGesture()
            view.addGestureRecognizer(pan)
            input.move(to: CGPoint(x: 0.25, y: 0.25))
            input.modifier(.option)
            input.beginDrag()
            events.value.removeAll()
            pan.reportedLocation = CGPoint(x: 120, y: 150)
            pan.reportedTranslation = CGPoint(x: 20, y: 0)
            pan.reportedState = .began
            control.pan(pan)
            pan.reportedLocation = CGPoint(x: 450, y: 350)
            pan.reportedTranslation = CGPoint(x: 330, y: 200)
            pan.reportedState = .changed
            control.pan(pan)
            #expect(input.isDragging)
            #expect(events.value.last?.x == 1 && events.value.last?.y == 1)
            pan.reportedState = .cancelled
            control.pan(pan)
            #expect(!input.isDragging && input.modifiers.isEmpty)
            #expect(events.value.last?.kind == .releaseAll)
        }
    }

    @Test func directScrollTargetsTouchLocationWithoutDragging() throws {
        try withInput { _, input, control, view, events in
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick, revealControls: nil)
            let pan = TestPanGesture()
            view.addGestureRecognizer(pan)
            input.toggleScroll()
            input.modifier(.shift)
            events.value.removeAll()
            pan.reportedLocation = CGPoint(x: 100, y: 170)
            pan.reportedTranslation = CGPoint(x: 0, y: 20)
            pan.reportedState = .began
            control.pan(pan)
            #expect(events.value.first?.kind == .move)
            #expect(events.value.first?.x == 0.25 && events.value.first?.y == 0.25)
            #expect(events.value.last?.kind == .scroll)
            pan.reportedState = .ended
            control.pan(pan)
            #expect(events.value.last?.kind == .keyUp)
            #expect(!input.isDragging)
        }
    }

    @Test func scrollStartingInMarginCannotScrollPreviousMacTarget() throws {
        try withInput { _, _, control, view, events in
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .rightClick, revealControls: nil)
            let scroll = TestPanGesture()
            view.addGestureRecognizer(scroll)
            events.value.removeAll()
            scroll.reportedLocation = CGPoint(x: 100, y: 40)
            scroll.reportedTranslation = CGPoint(x: 0, y: 20)
            scroll.reportedState = .began
            control.scroll(scroll)
            scroll.reportedLocation = CGPoint(x: 100, y: 150)
            scroll.reportedState = .changed
            control.scroll(scroll)
            scroll.reportedState = .ended
            control.scroll(scroll)
            #expect(events.value.isEmpty)
        }
    }

    @Test func changingModeReleasesHeldInputAndResetsTapSequence() throws {
        try withInput { _, input, control, view, events in
            control.click(at: CGPoint(x: 100, y: 150), in: view.bounds, time: 10)
            input.modifier(.command); input.beginDrag()
            control.configure(view: view, enabled: true, mode: .direct, aspect: 2, doubleTapAction: .doubleClick, revealControls: nil)
            #expect(!input.isDragging && input.modifiers.isEmpty)
            #expect(events.value.last?.kind == .releaseAll)
            events.value.removeAll()
            control.click(at: CGPoint(x: 100, y: 150), in: view.bounds, time: 10.2)
            #expect(events.value.last?.clickCount == 1)
        }
    }

    @Test func viewOnlySessionCanRestoreControlsWithoutRemoteClicks() throws {
        try withInput { _, _, control, view, events in
            var reveals = 0
            control.configure(view: view, enabled: false, mode: .direct, aspect: 2, doubleTapAction: .rightClick,
                              revealControls: { reveals += 1 })
            events.value.removeAll()
            control.click(at: CGPoint(x: 100, y: 150), in: view.bounds, time: 10)
            control.rightClick(at: CGPoint(x: 100, y: 150), in: view.bounds)
            #expect(events.value.isEmpty)
            #expect(control.accessibilityActions.map(\.name) == ["Show controls"])
            #expect(control.accessibleShowControls())
            #expect(reveals == 1)
            #expect(events.value.allSatisfy { $0.kind == .releaseAll })
        }
    }

    private func withInput(_ check: (AppSettings, SessionInputController, PointerSurface.Coordinator, UIView, EventBox) throws -> Void) throws {
        let suite = "DirectTouch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let input = SessionInputController(settings: settings)
        let control = PointerSurface.Coordinator(input: input)
        let events = EventBox()
        input.emit = { events.value.append($0) }
        try check(settings, input, control, UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400)), events)
    }

    private final class EventBox { var value: [InputEvent] = [] }
}
