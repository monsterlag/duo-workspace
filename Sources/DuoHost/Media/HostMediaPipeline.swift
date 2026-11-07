import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import DuoCore

@MainActor
final class HostMediaPipeline {
    struct Configuration {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let desktop: DesktopSize?
        let quality: StreamQuality
        /// The client echoes identified frames, so pacing and bitrate follow its acks.
        var acknowledgesFrames = false
    }

    typealias StartupError = MediaDeliveryLifetime.StartupError

    let configuration: Configuration
    var onFailure: ((CaptureFailure) -> Void)?
    private let transport: SecureChannel
    private let audio: HostAudioStream
    private let id = UUID()
    private var capture: CaptureEngine?
    private var encoder: H264Encoder?
    private var outstanding = false
    private var rate: StreamRateController
    private var unsent = 0
    private var nextFrameID = UInt32.random(in: .min ... .max)
    private struct Picture { let buffer: CVPixelBuffer; let time: CMTime; var retried = false }
    /// The newest capture not yet encoded. ScreenCaptureKit sends nothing more on a
    /// static screen, so a frame held back by pacing is encoded once room frees up.
    private var pending: Picture?
    /// Frames in the encoder, oldest first.
    private var submitted = [Picture]()
    private var lastTime = CMTime.invalid
    private let lifetime = MediaDeliveryLifetime()
    private var retired: Bool { !lifetime.isActive }

    init(configuration: Configuration, transport: SecureChannel, audio: HostAudioStream) {
        self.configuration = configuration; self.transport = transport; self.audio = audio
        rate = StreamRateController(maximumBitRate: configuration.quality.bitRate,
                                    framesPerSecond: configuration.quality.framesPerSecond)
    }

    /// `arrival` is when the channel decoded the ack; `held` is the client's coalescing delay.
    func acknowledge(_ id: UInt32, at arrival: TimeInterval, held: TimeInterval) {
        guard !retired, configuration.acknowledgesFrames else { return }
        rate.acknowledged(id: id, at: arrival, held: held)
        applyRate(at: ProcessInfo.processInfo.systemUptime)
        pump()
    }

    private func applyRate(at now: TimeInterval) {
        if let bitRate = rate.update(at: now) { encoder?.setBitRate(bitRate) }
    }

    /// Without acks, one frame at a time is encoded or awaiting transmission.
    /// With acks, frames in flight cover the round trip; newer captures replace the pending one.
    private func admit(_ encoder: H264Encoder) -> Bool {
        guard configuration.acknowledgesFrames else {
            guard !outstanding else { return false }
            outstanding = true; return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        applyRate(at: now)
        guard submitted.count < 2 else { return false }
        switch rate.admit(at: now, unsent: unsent) {
        case .wait: return false
        case .resync: encoder.requestKeyFrame()
        case .send: break
        }
        return true
    }

    private func pump() {
        guard !retired, let encoder, let picture = pending, admit(encoder) else { return }
        pending = nil
        // Re-encoded or delayed pictures must still have increasing timestamps.
        var time = picture.time
        if lastTime.isValid, time <= lastTime { time = CMTimeAdd(lastTime, CMTime(value: 1, timescale: 1000)) }
        lastTime = time
        submitted.append(Picture(buffer: picture.buffer, time: time, retried: picture.retried))
        encoder.encode(picture.buffer, time: time)
    }

    private func encoded(discarded: Bool) {
        let picture = submitted.isEmpty ? nil : submitted.removeFirst()
        // A dropped frame may be the last picture of a static screen: encode it again, once.
        if discarded, pending == nil, submitted.isEmpty, var picture, !picture.retried {
            picture.retried = true; pending = picture
        }
        if !configuration.acknowledgesFrames, discarded { outstanding = false }
        pump()
    }

    func start() async throws {
        guard !retired, capture == nil else { throw CancellationError() }
        let acknowledged = configuration.acknowledgesFrames
        let encoder = try H264Encoder(width: configuration.width, height: configuration.height,
            bitRate: acknowledged ? rate.targetBitRate : configuration.quality.bitRate,
            framesPerSecond: configuration.quality.framesPerSecond, keyFrameInterval: acknowledged ? nil : 2)
        self.encoder = encoder
        encoder.onDiscard = { [weak self] in Task { @MainActor in
            guard let self, !self.retired else { return }
            self.encoded(discarded: true)
        } }
        encoder.onOutput = { [weak self] frame in Task { @MainActor in
            guard let self, !self.retired else { return }
            if let config = frame.configuration { self.transport.send(.videoConfiguration, object: config) }
            if acknowledged {
                self.nextFrameID &+= 1
                let payload = TimedVideoFrame(id: self.nextFrameID, time: frame.time, data: frame.data).encoded()
                self.rate.sent(id: self.nextFrameID, bytes: payload.count, at: ProcessInfo.processInfo.systemUptime)
                self.unsent += 1
                self.transport.send(.identifiedVideoFrame, payload: payload) { [weak self] in Task { @MainActor in
                    guard let self, !self.retired else { return }
                    self.unsent = max(0, self.unsent - 1); self.pump()
                } }
                self.lifetime.firstFrame()
                self.encoded(discarded: false)
                return
            }
            let timed = self.audio.usesMediaTiming
            let payload = timed ? TimedVideoFrame(time: frame.time, data: frame.data).encoded() : frame.data
            self.transport.send(timed ? .timedVideoFrame : .videoFrame, payload: payload) { [weak self] in Task { @MainActor in
                guard let self, !self.retired else { return }
                self.outstanding = false; self.pump()
            } }
            self.lifetime.firstFrame()
            self.encoded(discarded: false)
        } }
        let capture = CaptureEngine()
        self.capture = capture
        audio.beginCapture(id)
        capture.onAudio = { [weak self] frame in Task { @MainActor in
            guard let self, !self.retired else { return }
            self.audio.send(frame, from: self.id)
        } }
        capture.onAudioError = { [weak self] in Task { @MainActor in
            guard let self, !self.retired, self.audio.enabled else { return }
            self.audio.captureFailed()
            try? await self.setAudioEnabled(false)
        } }
        capture.onFrame = { [weak self] buffer, time in Task { @MainActor in
            guard let self, !self.retired else { return }
            self.pending = Picture(buffer: buffer, time: time); self.pump()
        } }
        capture.onError = { [weak self] failure in Task { @MainActor in
            guard let self, !self.retired else { return }
            self.lifetime.fail(failure)
            self.onFailure?(failure)
        } }
        let expected = configuration.desktop.map { CGSize(width: $0.width, height: $0.height) }
        try await capture.start(displayID: configuration.displayID, width: configuration.width,
            height: configuration.height, framesPerSecond: configuration.quality.framesPerSecond, expectedLogicalSize: expected, audioEnabled: audio.enabled)
        guard !retired else { await capture.stop(); throw CancellationError() }
    }

    func setAudioEnabled(_ enabled: Bool) async throws {
        guard !retired else { throw CancellationError() }
        try await capture?.setAudioEnabled(enabled)
    }

    func waitForFirstFrame(until deadline: TimeInterval) async throws {
        try await lifetime.waitForFirstFrame(until: deadline)
    }

    func retire() {
        guard !retired else { return }
        lifetime.retire(); onFailure = nil
        pending = nil; submitted.removeAll()
        audio.endCapture(id)
    }

    func stop() async {
        retire()
        let previousCapture = capture, previousEncoder = encoder
        capture = nil; encoder = nil; outstanding = false; unsent = 0
        await lifetime.finish {
            await previousCapture?.stop()
            previousEncoder?.finish()
        }
    }
}
