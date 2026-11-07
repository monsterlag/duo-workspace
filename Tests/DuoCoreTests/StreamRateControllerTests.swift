import Foundation
import Testing
@testable import DuoCore

struct StreamRateControllerTests {
    /// Captures at 60 fps for `duration` seconds, sending what the controller admits;
    /// the client acks each frame `delay` seconds after it was sent.
    private func run(_ rate: inout StreamRateController, from start: TimeInterval, duration: TimeInterval,
                     delay: TimeInterval, bytes: (Int) -> Int, ids: inout UInt32) -> [Int] {
        var pending = [(id: UInt32, at: TimeInterval)]()
        var targets = [rate.targetBitRate]
        let frames = Int(duration * 60)
        for frame in 0..<frames {
            let now = start + Double(frame) / 60
            while let ack = pending.first, ack.at <= now {
                pending.removeFirst(); rate.acknowledged(id: ack.id, at: ack.at)
            }
            if let target = rate.update(at: now) { targets.append(target) }
            guard rate.admit(at: now) != .wait else { continue }
            ids &+= 1
            rate.sent(id: ids, bytes: bytes(rate.targetBitRate), at: now)
            pending.append((ids, now + delay))
        }
        for ack in pending { rate.acknowledged(id: ack.id, at: ack.at) }
        return targets
    }

    /// Frames that use the whole cap, as busy content does.
    private let full: (Int) -> Int = { $0 / 8 / 60 }

    @Test func slowStartRampsToTheCapWhileContentUsesIt() {
        var rate = StreamRateController(maximumBitRate: 20_000_000, framesPerSecond: 60)
        var ids: UInt32 = 0
        #expect(rate.targetBitRate == StreamRateController.startBitRate)
        let targets = run(&rate, from: 0, duration: 3, delay: 0.02, bytes: full, ids: &ids)
        #expect(Array(targets.prefix(4)) == [8_000_000, 12_000_000, 18_000_000, 20_000_000])
        #expect(rate.targetBitRate == 20_000_000)
    }

    @Test func queueDelayBacksOffTowardDeliveredRate() {
        var rate = StreamRateController(maximumBitRate: 20_000_000, framesPerSecond: 60)
        var ids: UInt32 = 0
        _ = run(&rate, from: 0, duration: 3, delay: 0.02, bytes: full, ids: &ids)
        let peak = rate.targetBitRate
        let targets = run(&rate, from: 3, duration: 1, delay: 0.12, bytes: full, ids: &ids)
        #expect(rate.queueMilliseconds > 30)
        #expect(targets.dropFirst().allSatisfy { $0 < peak })
        #expect(rate.targetBitRate <= peak * 85 / 100)
        // After congestion it probes gently instead of slow-starting again.
        let recovered = run(&rate, from: 4, duration: 2, delay: 0.02, bytes: full, ids: &ids)
        for (before, after) in zip(recovered, recovered.dropFirst()) where after > before {
            #expect(Double(after) <= Double(before) * 1.06 + 100_000 + 1)
        }
    }

    @Test func idleScreenDoesNotRaiseTheCap() {
        var rate = StreamRateController(maximumBitRate: 20_000_000, framesPerSecond: 60)
        var ids: UInt32 = 0
        let targets = run(&rate, from: 0, duration: 5, delay: 0.02, bytes: { _ in 2_000 }, ids: &ids)
        #expect(targets == [StreamRateController.startBitRate])
        let capped = StreamRateController(maximumBitRate: 3_000_000, framesPerSecond: 60)
        #expect(capped.targetBitRate == 3_000_000)
    }

    @Test func inFlightFramesCoverTheRoundTripAndStallsResync() {
        var rate = StreamRateController(maximumBitRate: 20_000_000, framesPerSecond: 60)
        // No RTT sample yet: 40 ms assumed, so ceil(80 / 16.7) + 2 = 7 frames or 160 ms.
        var admitted = 0
        for frame in 0..<12 {
            let now = Double(frame) / 60
            guard rate.admit(at: now) == .send else { continue }
            admitted += 1; rate.sent(id: UInt32(frame), bytes: 10_000, at: now)
        }
        #expect(admitted == 7 && rate.framesInFlight == 7)
        rate.acknowledged(id: 3, at: 0.2)
        #expect(rate.framesInFlight == 3)
        rate.acknowledged(id: 99, at: 0.2)
        #expect(rate.framesInFlight == 3)
        #expect(rate.admit(at: 0.21) == .send)
        // Frames older than RTT + 120 ms block sending; past 4 s the client is resynced.
        #expect(rate.admit(at: 0.4) == .wait)
        #expect(rate.admit(at: 4.2) == .resync)
        #expect(rate.framesInFlight == 0 && rate.admit(at: 4.2) == .send)
        // Frames the transport still holds bound the queue and defer the resync.
        rate.sent(id: 20, bytes: 10_000, at: 4.2)
        #expect(rate.admit(at: 4.21, unsent: rate.maximumInFlight) == .wait)
        #expect(rate.admit(at: 9, unsent: 1) == .wait && rate.framesInFlight == 1)
        #expect(rate.admit(at: 9, unsent: 0) == .resync)
    }

    @Test func roundTripUsesALongWindowAndCumulativeAcks() {
        var rate = StreamRateController(maximumBitRate: 20_000_000, framesPerSecond: 60)
        // One coalesced ack covers three frames; the client's hold time is not path delay.
        for id in UInt32(1)...3 { rate.sent(id: id, bytes: 10_000, at: Double(id) * 0.01) }
        rate.acknowledged(id: 3, at: 0.08, held: 0.03)
        #expect(rate.framesInFlight == 0 && rate.minimumRoundTrip.map { abs($0 - 20) < 0.001 } == true)
        var ids: UInt32 = 3
        _ = run(&rate, from: 1, duration: 2, delay: 0.02, bytes: { _ in 2_000 }, ids: &ids)
        // Queueing during congestion stays out of the base delay...
        _ = run(&rate, from: 3, duration: 2, delay: 0.12, bytes: { _ in 2_000 }, ids: &ids)
        #expect(rate.minimumRoundTrip.map { abs($0 - 20) < 1 } == true && rate.queueMilliseconds > 90)
        // ...until the 10 s window has moved past every faster sample.
        _ = run(&rate, from: 5, duration: 10, delay: 0.12, bytes: { _ in 2_000 }, ids: &ids)
        #expect(rate.minimumRoundTrip.map { abs($0 - 120) < 1 } == true && rate.queueMilliseconds < 5)
    }
}
