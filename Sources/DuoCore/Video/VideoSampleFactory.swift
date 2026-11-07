import Foundation
import CoreMedia
import AVFoundation

public final class VideoSampleFactory {
    private var format:CMVideoFormatDescription?
    public init(){}
    public func reset() { format = nil }
    public func configure(_ config:VideoConfiguration) throws {
        format = nil
        guard VideoRasterLimits.contains(width: config.width, height: config.height),!config.sps.isEmpty,!config.pps.isEmpty,config.sps.count<=4096,config.pps.count<=4096 else {throw WireError.oversized}
        var candidate: CMVideoFormatDescription?
        let status=config.sps.withUnsafeBytes{ s in config.pps.withUnsafeBytes{ p in
            let pointers=[s.bindMemory(to:UInt8.self).baseAddress!,p.bindMemory(to:UInt8.self).baseAddress!]
            let sizes=[s.count,p.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:nil,parameterSetCount:2,parameterSetPointers:pointers,parameterSetSizes:sizes,nalUnitHeaderLength:4,formatDescriptionOut:&candidate)
        }}
        guard status==noErr, let candidate else{throw NSError(domain:"DuoVideo",code:Int(status))}
        let size = CMVideoFormatDescriptionGetDimensions(candidate)
        guard Int(size.width) == config.width, Int(size.height) == config.height,
              VideoRasterLimits.contains(width: Int(size.width), height: Int(size.height)) else { throw WireError.invalidVideo }
        format = candidate
    }
    public func sample(_ data:Data) throws -> CMSampleBuffer {
        guard let format, let unit = H264AccessUnit(data) else{throw WireError.invalidVideo}
        var block:CMBlockBuffer?
        var status=CMBlockBufferCreateWithMemoryBlock(allocator:nil,memoryBlock:nil,blockLength:data.count,blockAllocator:nil,customBlockSource:nil,offsetToData:0,dataLength:data.count,flags:0,blockBufferOut:&block)
        guard status==noErr,let block else{throw NSError(domain:"DuoVideo",code:Int(status))}
        status=data.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:data.count)}
        guard status==noErr else{throw NSError(domain:"DuoVideo",code:Int(status))}
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:60),presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
        var size=data.count,sample:CMSampleBuffer?
        status=CMSampleBufferCreateReady(allocator:nil,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)
        guard status==noErr,let sample else{throw NSError(domain:"DuoVideo",code:Int(status))}
        if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) {
            let dict=unsafeBitCast(CFArrayGetValueAtIndex(attachments,0),to:NSMutableDictionary.self)
            dict[kCMSampleAttachmentKey_DisplayImmediately]=true
            dict[kCMSampleAttachmentKey_NotSync] = !unit.isKeyframe
        }
        return sample
    }
}
