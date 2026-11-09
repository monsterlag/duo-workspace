import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import DuoCore
import os

public final class H264Encoder {
    public var onOutput: ((EncodedVideoFrame) -> Void)?
    public var onDiscard:(()->Void)?
    private var session:VTCompressionSession?
    private var sentSPS:Data?
    private let width:Int,height:Int
    private let frameDuration: CMTime
    private let keyFrameLock = NSLock()
    private var forceKeyFrame = false
    private var rejectedProperties = Set<String>()
    private static let log = Logger(subsystem: "DuoWorkspace", category: "Encoder")
    /// `keyFrameInterval` nil means keyframes only on demand (the first frame and `requestKeyFrame()`).
    public init(width:Int,height:Int,bitRate:Int = 6_000_000,framesPerSecond:Int = 60,keyFrameInterval:TimeInterval? = 2) throws {
        guard VideoRasterLimits.contains(width: width, height: height) else { throw WireError.oversized }
        self.width=width;self.height=height
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
        // Apple's low-latency rate control (as in its conferencing sample): one IDR then P frames only,
        // no reordering or look-ahead, High profile. Fall back to the plain hardware encoder without it.
        var status=createSession(lowLatency:true)
        let lowLatency = status==noErr
        if !lowLatency {
            Self.log.error("Low-latency encoder unavailable (\(status)); using the standard encoder")
            status=createSession(lowLatency:false)
        }
        guard status==noErr,let session else{throw NSError(domain:"DuoEncoder",code:Int(status))}
        set(kVTCompressionPropertyKey_RealTime,kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate,framesPerSecond as CFNumber)
        // Low-latency rate control already favours speed and rejects this key (-12900).
        if !lowLatency { set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,kCFBooleanTrue) }
        // Periodic keyframes spike delay on a paced link; a reliable transport only needs them on demand.
        let interval = keyFrameInterval ?? 3600
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval,max(1, Int(interval * Double(framesPerSecond))) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,interval as CFNumber)
        setBitRate(bitRate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    /// Changes the target bitrate on the live session. Bursts are capped at 1.5x over
    /// one second and 1.5x of the 100 ms budget, so no single frame is far above it.
    public func setBitRate(_ bitRate:Int){
        let rate=min(20_000_000,max(250_000,bitRate))
        set(kVTCompressionPropertyKey_AverageBitRate,rate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits,[Double(rate) / 8 * 1.5, 1, Double(rate) / 80 * 1.5, 0.1] as CFArray)
    }
    private func createSession(lowLatency:Bool)->OSStatus{
        var specification:[CFString:Any]=[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:true]
        if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl]=true }
        return VTCompressionSessionCreate(allocator:nil,width:Int32(width),height:Int32(height),codecType:kCMVideoCodecType_H264,
            encoderSpecification:specification as CFDictionary,
            imageBufferAttributes:nil,compressedDataAllocator:nil,outputCallback:{ ref,_,status,_,sample in
                guard let ref else{return}
                let encoder = Unmanaged<H264Encoder>.fromOpaque(ref).takeUnretainedValue()
                guard status==noErr, let sample else{encoder.onDiscard?();return}
                encoder.output(sample)
            },refcon:Unmanaged.passUnretained(self).toOpaque(),compressionSessionOut:&session)
    }
    private func set(_ key:CFString,_ value:CFTypeRef){
        guard let session else{return}
        let status=VTSessionSetProperty(session,key:key,value:value)
        guard status != noErr, rejectedProperties.insert(key as String).inserted else{return}
        Self.log.error("VTSessionSetProperty \(key as String, privacy: .public) failed: \(status)")
    }
    /// Frames are encoded as keyframes until one is emitted.
    public func requestKeyFrame(){keyFrameLock.withLock{forceKeyFrame=true}}
    public func encode(_ buffer:CVPixelBuffer,time:CMTime){
        guard let session else{return}
        let properties = keyFrameLock.withLock{forceKeyFrame} ? [kVTEncodeFrameOptionKey_ForceKeyFrame:kCFBooleanTrue] as CFDictionary : nil
        let result = VTCompressionSessionEncodeFrame(session,imageBuffer:buffer,presentationTimeStamp:time,duration:frameDuration,frameProperties:properties,sourceFrameRefcon:nil,infoFlagsOut:nil)
        if result != noErr { onDiscard?() }
    }
    public func finish(){if let session{VTCompressionSessionCompleteFrames(session,untilPresentationTimeStamp:.invalid)}}
    private func output(_ sample:CMSampleBuffer){
        var emitted = false
        defer { if !emitted { onDiscard?() } }
        guard let format=CMSampleBufferGetFormatDescription(sample),let block=CMSampleBufferGetDataBuffer(sample) else{return}
        var p:UnsafePointer<UInt8>?,length=0,count=0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,parameterSetIndex:0,parameterSetPointerOut:&p,parameterSetSizeOut:&length,parameterSetCountOut:&count,nalUnitHeaderLengthOut:nil)==noErr,let p else{return}
        let sps=Data(bytes:p,count:length)
        var configuration: VideoConfiguration?
        if sentSPS != sps {
            var q:UnsafePointer<UInt8>?,n=0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,parameterSetIndex:1,parameterSetPointerOut:&q,parameterSetSizeOut:&n,parameterSetCountOut:nil,nalUnitHeaderLengthOut:nil)==noErr,let q else{return}
            configuration = VideoConfiguration(width:width,height:height,sps:sps,pps:Data(bytes:q,count:n))
        }
        let n=CMBlockBufferGetDataLength(block);guard n>0 && n<PacketDecoder.maximumPayload else{return}
        var data=Data(count:n)
        let status=data.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:n,destination:$0.baseAddress!)}
        if status==noErr {
            emitted = true
            if Self.isKeyFrame(sample) { keyFrameLock.withLock{forceKeyFrame=false} }
            if configuration != nil { sentSPS = sps }
            onOutput?(EncodedVideoFrame(configuration: configuration, data: data, time: sample.presentationTimeStamp.seconds))
        }
    }
    private static func isKeyFrame(_ sample:CMSampleBuffer)->Bool{
        guard let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[CFString:Any]],
              let first=attachments.first else{return true}
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
    deinit{if let session{VTCompressionSessionInvalidate(session)}}
}
