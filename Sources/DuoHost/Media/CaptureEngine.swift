import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import AVFoundation
import DuoCore

public final class CaptureEngine:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    public var onFrame:((CVPixelBuffer,CMTime)->Void)?
    public var onError:((CaptureFailure)->Void)?
    public var onAudio: ((AudioFrame) -> Void)?
    public var onAudioError: (() -> Void)?
    private var audioEncoder: AACAudioEncoder?
    private let audioQueue = DispatchQueue(label: "DuoWorkspace.AudioCapture")
    @MainActor private var configuration: SCStreamConfiguration?
    @MainActor private var stream:SCStream?
    @MainActor private var startup: Task<Void, Error>?
    @MainActor private var teardown: Task<Void, Never>?
    @MainActor private var stopped = false
    private let queue=DispatchQueue(label:"DuoWorkspace.Capture")
    @MainActor
    public func start(displayID:CGDirectDisplayID,width:Int=1600,height:Int=1000,framesPerSecond:Int=60,expectedLogicalSize:CGSize?=nil,audioEnabled:Bool=false) async throws {
        guard CGPreflightScreenCaptureAccess() else {throw NSError(domain:"DuoCapture",code:1,userInfo:[NSLocalizedDescriptionKey:"Screen Recording permission is required"])}
        try await runStartup { [self] in
            try await prepareStream(displayID: displayID, width: width, height: height,
                                    framesPerSecond: framesPerSecond, expectedLogicalSize: expectedLogicalSize, audioEnabled: audioEnabled)
        }
    }
    @MainActor
    func runStartup(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard !stopped, startup == nil, stream == nil else { throw CancellationError() }
        let pending = Task { @MainActor in
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
        }
        startup = pending
        defer { startup = nil }
        try await pending.value
    }
    @MainActor
    private func prepareStream(displayID: CGDirectDisplayID, width: Int, height: Int,
                               framesPerSecond: Int, expectedLogicalSize: CGSize?, audioEnabled: Bool) async throws {
        var selected: SCDisplay?
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if let display = content.displays.first(where: { $0.displayID == displayID }),
               expectedLogicalSize == nil || display.frame.size == expectedLogicalSize {
                selected = display; break
            }
            try await Task.sleep(for: .milliseconds(80))
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let display = selected else { throw NSError(domain: "DuoCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Display size is not ready"] ) }
        let filter=SCContentFilter(display:display,excludingWindows:[])
        let config=SCStreamConfiguration()
        config.width=width;config.height=height;config.pixelFormat=kCVPixelFormatType_32BGRA
        config.minimumFrameInterval=CMTime(value:1,timescale:CMTimeScale(min(60,max(15,framesPerSecond))));config.queueDepth=5
        config.showsCursor=true;config.capturesAudio=audioEnabled
        config.sampleRate=Int(AudioStreamFormat.sampleRate);config.channelCount=Int(AudioStreamFormat.channelCount);config.excludesCurrentProcessAudio=true
        configuration = config
        let s=SCStream(filter:filter,configuration:config,delegate:self)
        try s.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        try s.addStreamOutput(self,type:.audio,sampleHandlerQueue:audioQueue)
        stream=s;try await s.startCapture()
        try Task.checkCancellation()
    }
    @MainActor
    public func setAudioEnabled(_ enabled: Bool) async throws {
        guard let stream, let configuration, !stopped else { throw CancellationError() }
        audioQueue.async { [weak self] in self?.audioEncoder = nil }
        configuration.capturesAudio = enabled
        try await stream.updateConfiguration(configuration)
    }
    @MainActor
    public func stop() async {
        if let teardown { await teardown.value; return }
        stopped = true
        let pending = startup
        pending?.cancel()
        // Discovery/startCapture may finish after cancellation. Wait before
        // releasing the stream so the host can then remove its display.
        let task = Task { @MainActor [self] in
            _ = await pending?.result
            let previous = stream
            stream = nil
            try? await previous?.stopCapture()
        }
        teardown = task
        await task.value
    }
    public func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType){
        if type == .audio {
            guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let count = sampleBuffer.numSamples
            guard count > 0, count <= 8192,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
            pcm.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else { return }
            do {
                if audioEncoder == nil { audioEncoder = try AACAudioEncoder(format: format) }
                for frame in try audioEncoder?.encode(pcm, time: sampleBuffer.presentationTimeStamp.seconds) ?? [] { onAudio?(frame) }
            } catch { onAudioError?() }
            return
        }
        guard type == .screen,sampleBuffer.isValid,let image=CMSampleBufferGetImageBuffer(sampleBuffer) else{return}
        if let attachments=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],let raw=attachments.first?[.status] as? Int,raw != SCFrameStatus.complete.rawValue{return}
        onFrame?(image,CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
    public func stream(_ stream:SCStream,didStopWithError error:Error){onError?(CaptureFailure(error))}
}
