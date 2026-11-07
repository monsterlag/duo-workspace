import Foundation

/// Delay-based bitrate and frame pacing driven by per-frame acknowledgements.
///
/// Enough frames stay in flight to cover one round trip, but never more than about
/// the round trip plus 120 ms of queue. Acks that arrive later than the path's base
/// delay show queueing, so the cap backs off toward the measured delivery rate; it
/// probes upward only while the content actually uses it. Times are seconds.
public struct StreamRateController: Sendable {
    public enum Admission: Equatable, Sendable {
        case send, wait
        /// The client stopped acknowledging; in-flight state was cleared. Send a keyframe.
        case resync
    }

    public static let startBitRate = 8_000_000
    public static let minimumBitRate = 500_000

    private struct Inflight: Sendable { let id: UInt32; let sent: TimeInterval; let bytes: Int }

    private let maximum: Double
    private let minimum: Double
    private let intervalMilliseconds: Double
    private var target: Double
    private var inflight = [Inflight]()
    /// Per-second minimum send-to-ack times over the last 10 s.
    private var roundTrips = [(second: Int, milliseconds: Double)]()
    public private(set) var queueMilliseconds = 0.0
    private var windowStart: TimeInterval?
    private var windowBytes = 0
    public private(set) var deliveredBitRate = 0.0
    private var started = false
    private var lastEvaluation = -Double.infinity
    private var lastDecrease = -Double.infinity
    private var lastIncrease = -Double.infinity
    private var slowStart = true
    private var ceiling = Double.infinity
    private var ceilingAt = -Double.infinity

    public init(maximumBitRate: Int, minimumBitRate: Int = Self.minimumBitRate, framesPerSecond: Int) {
        minimum = Double(max(1, minimumBitRate))
        maximum = max(minimum, Double(maximumBitRate))
        intervalMilliseconds = 1000 / Double(max(1, framesPerSecond))
        target = min(Double(Self.startBitRate), maximum)
    }

    public var targetBitRate: Int { Int(target) }
    public var framesInFlight: Int { inflight.count }
    /// Smallest send-to-ack time over the last 10 s, in milliseconds. It is also the
    /// base delay: a longer window keeps queueing during congestion out of it.
    public var minimumRoundTrip: Double? { roundTrips.map(\.milliseconds).min() }
    /// Frames allowed in flight: one round trip plus decode, two spare.
    public var maximumInFlight: Int {
        min(40, max(3, Int((((minimumRoundTrip ?? 40) + 40) / intervalMilliseconds).rounded(.up)) + 2))
    }

    /// Whether a newly captured frame may be encoded and sent now. `unsent` counts
    /// frames the transport still holds; they bound the queue and defer a resync.
    public mutating func admit(at now: TimeInterval, unsent: Int = 0) -> Admission {
        guard unsent < maximumInFlight else { return .wait }
        guard let first = inflight.first else { return .send }
        let rtt = minimumRoundTrip ?? 40
        let age = (now - first.sent) * 1000
        if age > 4000 {
            guard unsent == 0 else { return .wait }
            inflight.removeAll(); started = false
            return .resync
        }
        return inflight.count >= maximumInFlight || age > rtt + 120 ? .wait : .send
    }

    public mutating func sent(id: UInt32, bytes: Int, at now: TimeInterval) {
        inflight.append(Inflight(id: id, sent: now, bytes: bytes))
        started = true
        if windowStart == nil { windowStart = now }
    }

    /// Acks are cumulative: `id` covers every earlier frame. `held` is how long the
    /// client kept the ack back to coalesce it, and is excluded from the delay sample.
    public mutating func acknowledged(id: UInt32, at now: TimeInterval, held: TimeInterval = 0) {
        guard let index = inflight.firstIndex(where: { $0.id == id }) else { return }
        let acknowledged = inflight[...index].reduce(0) { $0 + $1.bytes }
        let sample = max(1, (now - max(0, held) - inflight[index].sent) * 1000)
        inflight.removeFirst(index + 1)
        let second = Int(now.rounded(.down))
        roundTrips.removeAll { $0.second <= second - 10 }
        if let last = roundTrips.last, last.second == second {
            roundTrips[roundTrips.count - 1].milliseconds = min(last.milliseconds, sample)
        } else { roundTrips.append((second, sample)) }
        queueMilliseconds = queueMilliseconds * 0.7 + (sample - (minimumRoundTrip ?? sample)) * 0.3
        windowBytes += acknowledged
        let elapsed = now - (windowStart ?? now)
        if elapsed >= 0.5 {
            let rate = Double(windowBytes) * 8 / elapsed
            deliveredBitRate = deliveredBitRate == 0 ? rate : deliveredBitRate * 0.6 + rate * 0.4
            windowBytes = 0; windowStart = now
        }
    }

    /// Re-evaluates the cap at most every 100 ms; returns the new target when it changed.
    public mutating func update(at now: TimeInterval) -> Int? {
        guard now - lastEvaluation >= 0.1 else { return nil }
        lastEvaluation = now
        var congested = false, clear = true, rate = Double.infinity, delivered = 0.0
        if started {
            let rtt = minimumRoundTrip ?? 40
            let age = inflight.first.map { (now - $0.sent) * 1000 } ?? 0
            if queueMilliseconds > 30 || age > rtt + 80 {
                congested = true
                if deliveredBitRate > 0 { rate = deliveredBitRate }
            }
            if queueMilliseconds > 15 { clear = false }
            delivered = deliveredBitRate
        }
        let previous = target
        if congested && now - lastDecrease >= 0.3 {
            var next = target * 0.85
            // Delivery rate only measures capacity when the stream was pushing near the cap.
            if rate.isFinite && rate >= target * 0.5 {
                ceiling = rate; ceilingAt = now
                next = min(next, rate * 0.85)
            }
            target = max(next, minimum)
            lastDecrease = now; slowStart = false
        } else if slowStart {
            // voxl falls through to the gentle probe between slow-start steps, which at a
            // 100 ms cadence replaces the 1.5x ramp with +6% steps; keep slow start whole.
            if !congested && clear && now - lastIncrease >= 0.25 && delivered >= target * 0.5 {
                target = min(target * 1.5, maximum)
                lastIncrease = now
            }
        } else if !congested && clear && now - lastDecrease >= 1 && delivered >= target * 0.5 {
            // An idle screen says nothing about the path; forget an unconfirmed capacity.
            if now - ceilingAt >= 15 { ceiling = .infinity }
            if target < ceiling * 0.9 && now - lastIncrease >= 0.2 {
                target = min(target * 1.06 + 100_000, ceiling * 0.9, maximum)
                lastIncrease = now
            } else if target >= ceiling * 0.9 && now - lastIncrease >= 1 {
                target = min(target * 1.02, maximum)
                lastIncrease = now
            }
        }
        return target != previous ? Int(target) : nil
    }
}
