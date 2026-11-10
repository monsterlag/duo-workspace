import UIKit

@MainActor
final class TestPanGesture: UIPanGestureRecognizer {
    var reportedState: UIGestureRecognizer.State = .possible
    var reportedTranslation = CGPoint.zero
    var reportedLocation = CGPoint.zero
    var reportedVelocity = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { reportedState }
        set { reportedState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { reportedTranslation }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { reportedTranslation = translation }
    override func location(in view: UIView?) -> CGPoint { reportedLocation }
    override func velocity(in view: UIView?) -> CGPoint { reportedVelocity }
}
