import UIKit
import Testing
import DuoCore
@testable import DuoWorkspace

@MainActor
struct NativeTouchClientTests {
    @Test func fullFrameVideoKeepsOrdinaryNativeEdgeHandling() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.setEnabled(true)
        session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 1, reservesEdges: false, cancellationID: session.cancellationID)
        #expect(view.edgeSwipeCandidate(at: CGPoint(x: 200, y: 390)) == nil)
    }

    @Test func deliberateResizePanDoesNotUseDockSpeedThreshold() throws {
        let name = "ResizeVelocity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let control = PointerSurface.Coordinator(input: SessionInputController(settings: AppSettings(defaults: defaults)))
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.setEnabled(true)
        session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        control.installGestures(on: view)
        control.configure(view: view, enabled: true, mode: .nativeTouch, aspect: 2,
                          doubleTapAction: .rightClick, revealControls: nil)
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        let gesture = TestPanGesture()
        view.addGestureRecognizer(gesture)
        gesture.reportedVelocity = CGPoint(x: 0, y: -80)
        #expect(control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 280)))
        #expect(!control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 320)))
        gesture.reportedVelocity = CGPoint(x: 0, y: 80)
        #expect(!control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 280)))
    }

    @Test func olderHostKeepsNativeImageInputWithoutClaimingTheBezel() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID()))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        #expect(session.isReady)
        #expect(view.edgeSwipeCandidate(at: CGPoint(x: 200, y: 390)) == nil)
        let finger = NSObject()
        view.beginNativeTouch(ObjectIdentifier(finger), at: CGPoint(x: 200, y: 200))
        view.publishNativeTouches()
        #expect(frames.last?.contacts.count == 1)
        #expect(frames.last?.contacts.first?.edgeGesture == nil)
    }

    @Test func cancelledDockSwipeRequiresAllFingersToLiftBeforeAnotherStart() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        view.cancelNativeTouches()
        #expect(!view.beginEdgeSwipe(at: CGPoint(x: 200, y: 380)))
        view.prepareNativeTouches([.stationary, .began])
        #expect(!view.beginEdgeSwipe(at: CGPoint(x: 200, y: 380)))
        view.prepareNativeTouches([.began])
        #expect(view.beginEdgeSwipe(at: CGPoint(x: 200, y: 380)))
        view.endEdgeSwipe()
    }

    @Test func dockSwipeRejectsSlowSidewaysAndDownwardStarts() throws {
        let name = "DockVelocity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let control = PointerSurface.Coordinator(input: SessionInputController(settings: AppSettings(defaults: defaults)))
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        control.installGestures(on: view)
        control.configure(view: view, enabled: true, mode: .nativeTouch, aspect: 2,
                          doubleTapAction: .rightClick, revealControls: nil)
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        let gesture = TestPanGesture()
        view.addGestureRecognizer(gesture)
        gesture.reportedLocation = CGPoint(x: 200, y: 310)
        gesture.reportedTranslation = CGPoint(x: 0, y: -10)
        gesture.reportedVelocity = CGPoint(x: 0, y: -350)
        #expect(control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 320)))
        gesture.reportedVelocity = CGPoint(x: 0, y: -80)
        #expect(!control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 320)))
        gesture.reportedVelocity = CGPoint(x: 400, y: -300)
        #expect(!control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 320)))
        gesture.reportedVelocity = CGPoint(x: 0, y: 350)
        #expect(!control.prepareEdgeSwipe(gesture, startingAt: CGPoint(x: 200, y: 320)))
        control.configure(view: view, enabled: true, mode: .direct, aspect: 2,
                          doubleTapAction: .rightClick, revealControls: nil)
        #expect(!view.bottomEdgeGesture.isEnabled)
    }

    @Test func dockSwipeDoesNotTakeAnExistingNativeContact() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        let finger = NSObject()
        view.beginNativeTouch(ObjectIdentifier(finger), at: CGPoint(x: 100, y: 100))
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 380)) == nil)
        #expect(!view.beginEdgeSwipe(at: CGPoint(x: 200, y: 380)))
    }

    @Test func dockSwipeIncludesBottomMarginButExcludesTopAndSideControls() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: true, cancellationID: session.cancellationID)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 275)) != nil)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 300)) != nil)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 267)) == nil)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 310)) != nil)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 390)) != nil)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 200, y: 90)) == nil)
        #expect(view.edgeSwipeStart(at: CGPoint(x: 5, y: 390)) == nil)
    }

    @Test func dockSwipeSendsNativeEdgePressThenFingerTranslationAndLift() throws {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        #expect(view.beginEdgeSwipe(at: CGPoint(x: 320, y: 390)))
        let first = try #require(frames.last?.contacts.first)
        #expect(first.x == 0.5 && abs(first.y - (1 - 1.0 / 32767)) < 0.00001)
        #expect(first.edgeGesture == .dock)
        view.moveEdgeSwipe(to: CGPoint(x: 340, y: 350))
        let moved = try #require(frames.last?.contacts.first)
        #expect(moved.id == first.id && moved.x == 0.55)
        #expect(moved.edgeGesture == .dock)
        #expect(abs(moved.y - (first.y - 0.2)) < 0.00001)
        view.endEdgeSwipe()
        #expect(frames.last?.contacts.isEmpty == true)
    }

    @Test func imageEdgeSwipeUsesFormerWindowResizeEndpoint() throws {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true)
        session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        #expect(view.beginEdgeSwipe(at: CGPoint(x: 320, y: 280)))
        let first = try #require(frames.last?.contacts.first)
        #expect(first.x == 0.5 && first.y == 1 && first.edgeGesture == .windowResize)
        view.moveEdgeSwipe(to: CGPoint(x: 340, y: 240))
        let moved = try #require(frames.last?.contacts.first)
        #expect(moved.x == 0.55 && moved.y == 0.8 && moved.edgeGesture == .windowResize)
        view.endEdgeSwipe()
        #expect(frames.last?.contacts.isEmpty == true)
    }

    @Test func cancelledDockSwipeCannotRestartOrMoveRetiredContext() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        #expect(view.beginEdgeSwipe(at: CGPoint(x: 200, y: 380)))
        session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        view.moveEdgeSwipe(to: CGPoint(x: 200, y: 250))
        view.endEdgeSwipe()
        #expect(frames.last?.contacts.isEmpty == true)
    }

    @Test func nativeContactIDsStayDistinctAndMatchTheVideo() throws {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var ended = 0
        session.gestureEnded = { ended += 1 }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true)
        session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 2, reservesEdges: false, cancellationID: session.cancellationID)
        let fingers = (0..<6).map { _ in NSObject() }
        view.beginNativeTouch(ObjectIdentifier(fingers[0]), at: CGPoint(x: 200, y: 20))
        view.publishNativeTouches()
        #expect(frames.last?.contacts.isEmpty == true)
        for (index, finger) in fingers.enumerated() {
            view.beginNativeTouch(ObjectIdentifier(finger), at: CGPoint(x: 80 + 40 * index, y: 150))
        }
        view.publishNativeTouches()
        let contacts = try #require(frames.last?.contacts)
        #expect(contacts.count == 5 && Set(contacts.map(\.id)).count == 5)
        #expect(contacts[0].x == 0.2 && contacts[0].y == 0.25)
        view.moveNativeTouch(ObjectIdentifier(fingers[0]), to: CGPoint(x: 900, y: -20))
        view.publishNativeTouches()
        #expect(frames.last?.contacts[0].id == contacts[0].id)
        #expect(frames.last?.contacts[0].x == 1 && frames.last?.contacts[0].y == 0)
        view.cancelNativeTouches()
        #expect(frames.last?.contacts.isEmpty == true)
        #expect(ended == 1)
    }

    @Test func revealEdgesDoNotSendNativeFingers() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 1, reservesEdges: true, cancellationID: session.cancellationID)
        let left = NSObject(), right = NSObject()
        view.beginNativeTouch(ObjectIdentifier(left), at: CGPoint(x: 5, y: 200))
        view.beginNativeTouch(ObjectIdentifier(right), at: CGPoint(x: 395, y: 200))
        view.publishNativeTouches()
        #expect(frames.last?.contacts.isEmpty == true)
    }

    @Test func contextChangesDropHeldFingersAndSwitchingOffStopsHeartbeats() async throws {
        let session = SessionNativeTouch()
        session.supported = true
        var controls: [Bool] = [], frames: [NativeTouchFrame] = []
        session.sendControl = { controls.append($0.enabled); return true }
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true)
        let first = UUID(), second = UUID()
        session.receive(NativeTouchStatus(.ready, contextID: first))
        session.updateContacts([.init(id: 1, x: 0.4, y: 0.6)])
        session.receive(NativeTouchStatus(.ready, contextID: second))
        #expect(frames.last?.contextID == second && frames.last?.contacts.isEmpty == true)
        session.setEnabled(false)
        let sent = frames.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.count == sent)
        #expect(controls == [true, false])
        #expect(!session.isReady)
    }

    @Test func externalCancellationPreventsHeldTouchesFromStartingAgain() {
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        var frames: [NativeTouchFrame] = []
        session.sendFrame = { frames.append($0) }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.configureNativeTouch(session, aspect: 1, reservesEdges: false, cancellationID: session.cancellationID)
        let finger = NSObject(), identity = ObjectIdentifier(finger)
        view.beginNativeTouch(identity, at: CGPoint(x: 100, y: 100))
        view.publishNativeTouches()
        session.cancelContacts()
        view.configureNativeTouch(session, aspect: 1, reservesEdges: false, cancellationID: session.cancellationID)
        view.moveNativeTouch(identity, to: CGPoint(x: 200, y: 200))
        view.publishNativeTouches()
        #expect(frames.last?.contacts.isEmpty == true)
    }

    @Test func nativeModeDisablesMouseGestureInterpretation() throws {
        let name = "NativeTouch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.pointerMode = .nativeTouch
        #expect(AppSettings(defaults: defaults).pointerMode == .nativeTouch)
        let input = SessionInputController(settings: settings)
        var events: [InputEvent] = []
        input.emit = { events.append($0) }
        let control = PointerSurface.Coordinator(input: input)
        let view = PointerPadView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        control.installGestures(on: view)
        control.configure(view: view, enabled: true, mode: .nativeTouch, aspect: 1,
                          doubleTapAction: .rightClick, revealControls: nil)
        events = []
        control.click(at: CGPoint(x: 100, y: 100), in: view.bounds, time: 1)
        control.rightClick(at: CGPoint(x: 100, y: 100), in: view.bounds)
        #expect(events.isEmpty)
    }

    @Test func explicitPointerControlsUseLastNativeTouchWithoutExtraMouseMovement() throws {
        let name = "NativePosition.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let input = SessionInputController(settings: AppSettings(defaults: defaults))
        let session = SessionNativeTouch()
        session.supported = true; session.sendControl = { _ in true }
        session.positionChanged = { input.rememberNativeTouch($0) }
        var events: [InputEvent] = []
        input.emit = { events.append($0) }
        session.setEnabled(true); session.receive(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        defer { session.disconnect() }
        session.updateContacts([.init(id: 6, x: 0.25, y: 0.75)])
        #expect(events.isEmpty)
        session.updateContacts([])
        input.click(right: true)
        #expect(events.count == 1)
        #expect(events.first?.kind == .rightClick)
        #expect(events.first?.x == 0.25 && events.first?.y == 0.75)
    }
}
