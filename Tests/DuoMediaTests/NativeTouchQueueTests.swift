import Testing
import DuoCore
@testable import DuoHost

@MainActor
struct NativeTouchQueueTests {
    @Test func resizeSwipeKeepsFormerFirstPositionWithoutDockQualification() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice(displayHeight: 1000)
        let edge = NativeTouchContact(id: 1, x: 0.5, y: 1, edgeGesture: .windowResize)
        let firstMove = NativeTouchContact(id: 1, x: 0.5, y: 0.8, edgeGesture: .windowResize)
        let latest = NativeTouchContact(id: 1, x: 0.5, y: 0.7, edgeGesture: .windowResize)
        device.enqueue([edge]); device.enqueue([firstMove]); device.enqueue([latest])
        #expect(device.pending == [[edge], [latest]])
    }

    @Test func bezelSwipePreservesEdgeQualificationBeforeCoalescedMovement() throws {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice(displayHeight: 1000)
        let edge = NativeTouchContact(id: 1, x: 0.5, y: 1, edgeGesture: .dock)
        let far = NativeTouchContact(id: 1, x: 0.5, y: 0.7, edgeGesture: .dock)
        device.enqueue([edge])
        device.enqueue([far])
        let frames = device.pending
        #expect(frames.count == 4)
        guard frames.count == 4 else { return }
        #expect(frames.first == [edge] && frames.last == [far])
        #expect(frames[1][0].id == edge.id && frames[2][0].id == edge.id)
        #expect(frames[1][0].x == edge.x && frames[2][0].x == edge.x)
        #expect(edge.y > frames[1][0].y && frames[1][0].y > frames[2][0].y)
        #expect(frames[2][0].y > 0.8)
        for index in 0..<1000 {
            device.enqueue([.init(id: 1, x: 0.5, y: 0.7 - Double(index) / 10000, edgeGesture: .dock)])
        }
        #expect(Array(device.pending.prefix(3)) == Array(frames.prefix(3)))
        #expect(device.pending.count == 4)
        device.releaseAll()
        #expect(device.pending.isEmpty)
    }

    @Test func ordinaryMovementKeepsOriginalLatestSampleCoalescing() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice()
        let edge = NativeTouchContact(id: 1, x: 0.5, y: 1)
        let middle = NativeTouchContact(id: 1, x: 0.5, y: 0.9)
        let latest = NativeTouchContact(id: 1, x: 0.5, y: 0.7)
        device.enqueue([edge])
        device.enqueue([middle])
        device.enqueue([latest])
        #expect(device.pending == [[latest]])
    }

    @Test func ordinaryPressLiftPressPreservesTransitionsAndLatestPositions() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice()
        let first = NativeTouchContact(id: 1, x: 0.2, y: 1)
        let firstMove = NativeTouchContact(id: 1, x: 0.2, y: 0.8)
        let second = NativeTouchContact(id: 1, x: 0.8, y: 1)
        let secondMove = NativeTouchContact(id: 1, x: 0.8, y: 0.6)
        device.enqueue([first])
        device.enqueue([firstMove])
        device.enqueue([])
        device.enqueue([second])
        device.enqueue([secondMove])
        #expect(device.pending == [[firstMove], [], [secondMove]])
    }

    @Test func ordinaryAddedFingerPreservesIDTransitionWhileCoalescingPositions() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice()
        let first = NativeTouchContact(id: 1, x: 0.2, y: 0.8)
        let second = NativeTouchContact(id: 2, x: 0.7, y: 1)
        let moved = NativeTouchContact(id: 2, x: 0.7, y: 0.5)
        device.enqueue([first])
        device.enqueue([first, second])
        device.enqueue([first, moved])
        // Reordering contacts does not create a new ID-set transition.
        device.enqueue([moved, first])
        #expect(device.pending == [[first], [moved, first]])
    }

    @Test func ordinaryMovementBurstUsesOnlyLatestPendingSample() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice()
        let edge = NativeTouchContact(id: 1, x: 0.5, y: 1)
        var failure: String?
        device.onFailure = { failure = $0 }
        device.enqueue([edge])
        for index in 1...1000 {
            device.enqueue([.init(id: 1, x: 0.5, y: 1 - Double(index) / 1000)])
        }
        #expect(device.pending == [[.init(id: 1, x: 0.5, y: 0)]])
        #expect(failure == nil)
    }

    @Test func transitionOverflowStillClearsQueueAndReportsFailure() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice()
        var failures = 0
        device.onFailure = { _ in failures += 1 }
        for index in 0..<65 {
            device.enqueue(index.isMultiple(of: 2) ? [.init(id: 1, x: 0.5, y: 1)] : [])
        }
        #expect(device.pending.isEmpty)
        #expect(failures == 1)
    }

    @Test func releaseAndOversizedFrameStillClearPendingSamples() {
        guard #available(macOS 15, *) else { return }
        let device = SystemNativeTouchDevice()
        device.enqueue([.init(id: 1, x: 0.5, y: 1)])
        device.enqueue([.init(id: 1, x: 0.5, y: 0.5)])
        device.releaseAll()
        #expect(device.pending.isEmpty)
        device.enqueue([.init(id: 1, x: 0.5, y: 1)])
        device.enqueue((1...6).map { .init(id: UInt8($0), x: 0.5, y: 1) })
        #expect(device.pending.isEmpty)
    }
}
