import UIKit
import DuoCore

final class PointerPadView: UIView {
    var onActivate: (() -> Bool)?
    private var nativeTouch: SessionNativeTouch?
    private var nativeContext: UUID?
    private var cancellationID: UInt64 = 0
    private var frameAspect = 1.0
    private var reservesRevealEdges = false
    private var contacts: [ObjectIdentifier: NativeTouchContact] = [:]
    private var nextID: UInt8 = 1
    private var waitingForLift = false
    private var previousBounds = CGRect.zero
    let bottomEdgeGesture = NativeEdgeSwipeGestureRecognizer()
    private let edgeSwipeFinger = NSObject()
    private var edgeSwipeOrigin: CGPoint?
    private var edgeSwipeTouchStart: CGPoint?

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        nativeTouch == nil ? super.editingInteractionConfiguration : .none
    }

    func configureNativeTouch(_ session: SessionNativeTouch?, aspect: Double, reservesEdges: Bool, cancellationID revision: UInt64) {
        let context = session?.status.contextID
        let firstAttachment = nativeTouch == nil
        if nativeTouch !== session || nativeContext != context || frameAspect != aspect {
            cancelNativeTouches()
        } else if cancellationID != revision {
            contacts.removeAll(); waitingForLift = true
            resetEdgeSwipe()
        }
        nativeTouch = session; nativeContext = context
        cancellationID = session == nil ? 0 : revision
        frameAspect = aspect; reservesRevealEdges = reservesEdges
        isMultipleTouchEnabled = true
        if firstAttachment { waitingForLift = false }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousBounds != .zero && previousBounds != bounds { cancelNativeTouches() }
        previousBounds = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelNativeTouches() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard nativeTouch?.isReady == true else { super.touchesBegan(touches, with: event); return }
        prepareNativeTouches(event?.allTouches?.map(\.phase) ?? [])
        guard !waitingForLift else { return }
        for touch in touches {
            beginNativeTouch(ObjectIdentifier(touch), at: touch.location(in: self))
        }
        publishNativeTouches()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard nativeTouch?.isReady == true else { super.touchesMoved(touches, with: event); return }
        guard !waitingForLift else { return }
        for touch in touches { moveNativeTouch(ObjectIdentifier(touch), to: touch.location(in: self)) }
        publishNativeTouches()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard nativeTouch != nil else { super.touchesEnded(touches, with: event); return }
        for touch in touches { contacts[ObjectIdentifier(touch)] = nil }
        if event?.allTouches?.allSatisfy({ [.ended, .cancelled].contains($0.phase) }) == true {
            waitingForLift = false
        }
        publishNativeTouches()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The edge recognizer owns these delayed touches once it begins.
        if edgeSwipeOrigin == nil && ![.began, .changed].contains(bottomEdgeGesture.state) { cancelNativeTouches() }
        super.touchesCancelled(touches, with: event)
    }

    func cancelNativeTouches() {
        contacts.removeAll(); waitingForLift = true
        resetEdgeSwipe()
        nativeTouch?.cancelContacts()
        cancellationID = nativeTouch?.cancellationID ?? 0
    }

    func prepareNativeTouches(_ phases: [UITouch.Phase]) {
        if !phases.isEmpty && phases.allSatisfy({ [.began, .ended, .cancelled].contains($0) }) {
            waitingForLift = false
        }
    }

    func edgeSwipeStart(at point: CGPoint) -> (origin: CGPoint, gesture: NativeTouchContact.EdgeGesture)? {
        guard !waitingForLift else { return nil }
        return edgeSwipeCandidate(at: point)
    }

    func edgeSwipeCandidate(at point: CGPoint) -> (origin: CGPoint, gesture: NativeTouchContact.EdgeGesture)? {
        guard contacts.isEmpty, nativeTouch?.isReady == true, nativeTouch?.status.supportsEdgeGestures == true,
              !reservesRevealEdges || !ControlsRevealGesture.startsAtEdge(point, in: bounds),
              let image = DesktopTouchGeometry.imageRect(in: bounds, aspect: frameAspect),
              bounds.maxY - image.maxY >= 1,
              point.x >= image.minX, point.x < image.maxX,
              point.y >= image.maxY - 32, point.y <= bounds.maxY else { return nil }
        if point.y > image.maxY {
            return (CGPoint(x: image.midX, y: image.maxY - image.height / 32767), .dock)
        }
        // Retain the exact endpoint used by the earlier window-resize path.
        return (CGPoint(x: image.midX, y: image.maxY), .windowResize)
    }

    @discardableResult
    func beginEdgeSwipe(at point: CGPoint) -> Bool {
        guard contacts.isEmpty, let candidate = edgeSwipeStart(at: point) else { return false }
        let edge = candidate.origin
        edgeSwipeOrigin = edge; edgeSwipeTouchStart = point
        beginNativeTouch(ObjectIdentifier(edgeSwipeFinger), at: edge)
        let key = ObjectIdentifier(edgeSwipeFinger)
        if let contact = contacts[key] {
            contacts[key] = NativeTouchContact(id: contact.id, x: contact.x, y: contact.y, edgeGesture: candidate.gesture)
        }
        publishNativeTouches()
        return true
    }

    func moveEdgeSwipe(to point: CGPoint) {
        guard let origin = edgeSwipeOrigin, let start = edgeSwipeTouchStart else { return }
        moveNativeTouch(ObjectIdentifier(edgeSwipeFinger),
                        to: CGPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
        publishNativeTouches()
    }

    func endEdgeSwipe() {
        guard edgeSwipeOrigin != nil else { return }
        contacts[ObjectIdentifier(edgeSwipeFinger)] = nil
        edgeSwipeOrigin = nil; edgeSwipeTouchStart = nil
        publishNativeTouches()
    }

    private func resetEdgeSwipe() {
        edgeSwipeOrigin = nil; edgeSwipeTouchStart = nil
        let enabled = bottomEdgeGesture.isEnabled
        bottomEdgeGesture.isEnabled = false
        bottomEdgeGesture.isEnabled = enabled
    }

    func beginNativeTouch(_ key: ObjectIdentifier, at point: CGPoint) {
        guard !waitingForLift, nativeTouch?.isReady == true, contacts.count < NativeTouchFrame.maximumContacts, contacts[key] == nil,
              !reservesRevealEdges || !ControlsRevealGesture.startsAtEdge(point, in: bounds),
              let normalized = DesktopTouchGeometry.normalized(point, in: bounds, aspect: frameAspect) else { return }
        while contacts.values.contains(where: { $0.id == nextID }) { nextID = nextID == 127 ? 1 : nextID + 1 }
        contacts[key] = NativeTouchContact(id: nextID, x: normalized.x, y: normalized.y)
        nextID = nextID == 127 ? 1 : nextID + 1
    }

    func moveNativeTouch(_ key: ObjectIdentifier, to point: CGPoint) {
        guard !waitingForLift, let contact = contacts[key],
              let normalized = DesktopTouchGeometry.normalized(point, in: bounds, aspect: frameAspect, clamped: true) else { return }
        contacts[key] = NativeTouchContact(id: contact.id, x: normalized.x, y: normalized.y,
                                           edgeGesture: contact.edgeGesture)
    }

    func publishNativeTouches() {
        nativeTouch?.updateContacts(contacts.values.sorted { $0.id < $1.id })
    }

    override func accessibilityActivate() -> Bool {
        isUserInteractionEnabled && (onActivate?() ?? false)
    }
}

/// Give taps, holds and slow drags back to the raw native-touch path promptly.
final class NativeEdgeSwipeGestureRecognizer: UIPanGestureRecognizer {
    private var decision: Task<Void, Never>?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        (view as? PointerPadView)?.prepareNativeTouches(event.allTouches?.map(\.phase) ?? [])
        super.touchesBegan(touches, with: event)
        guard numberOfTouches <= 1 else {
            if [.began, .changed].contains(state) { state = .cancelled }
            else if state == .possible { state = .failed }
            return
        }
        guard state == .possible else { return }
        decision?.cancel()
        decision = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.state == .possible else { return }
            self.state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if state != .possible { decision?.cancel() }
    }

    override func reset() {
        decision?.cancel(); decision = nil
        super.reset()
    }
}
