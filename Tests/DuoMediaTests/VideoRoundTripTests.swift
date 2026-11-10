import XCTest
import CoreVideo
import CoreMedia
import VideoToolbox
@testable import DuoCore
import DuoHost

final class VideoRoundTripTests: XCTestCase {
    func testEncodedFrameCanBeDecodedByClientPipeline() throws {
        try assertRoundTrip(width: 640, height: 480)
    }

    func testFullHDAndHighDetailPortraitCanBeDecoded() throws {
        try assertRoundTrip(width: 1920, height: 1080)
        try assertRoundTrip(width: 2004, height: 2852)
    }

    private func assertRoundTrip(width: Int, height: Int) throws {
        let decoded = expectation(description: "H.264 frame decoded")
        let factory = VideoSampleFactory()
        let encoder = try H264Encoder(width: width, height: height, bitRate: 20_000_000)
        var decoder: VTDecompressionSession?
        encoder.onOutput = { frame in
            if let configuration = frame.configuration {
                do { try factory.configure(configuration) }
                catch { XCTFail("Video configuration: \(error)") }
            }
            let data = frame.data
            do {
                let sample = try factory.sample(data)
                let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
                XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool, false)
                guard let format = CMSampleBufferGetFormatDescription(sample) else {
                    XCTFail("Missing H.264 format"); return
                }
                // The host captures in sRGB; the stream must say so, or a client guesses.
                XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                               kCMFormatDescriptionTransferFunction_sRGB as String)
                XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
                               kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
                let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                    decoderSpecification: nil, imageBufferAttributes: nil,
                    outputCallback: nil, decompressionSessionOut: &decoder)
                XCTAssertEqual(status, noErr)
                guard let decoder else { return }
                let decodeStatus = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
                    flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                        XCTAssertEqual(status, noErr)
                        guard let image else { XCTFail("No decoded image"); return }
                        XCTAssertEqual(CVPixelBufferGetWidth(image), width)
                        XCTAssertEqual(CVPixelBufferGetHeight(image), height)
                        decoded.fulfill()
                    }
                XCTAssertEqual(decodeStatus, noErr)
            } catch { XCTFail("Client sample creation: \(error)") }
        }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0x70, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        encoder.encode(image, time: CMTime(value: 1, timescale: 30))
        encoder.finish()
        wait(for: [decoded], timeout: 10)
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    func testSPSDimensionsMustMatchAndResetRequiresNewConfiguration() throws {
        let checked = expectation(description: "Configuration checked")
        let factory = VideoSampleFactory()
        let encoder = try H264Encoder(width: 640, height: 480)
        encoder.onOutput = { frame in
            let config = frame.configuration, data = frame.data
            guard let config else { XCTFail("Missing configuration"); return }
            do {
                try factory.configure(config)
                XCTAssertNoThrow(try factory.sample(data))
                let interFrame = try factory.sample(Data([0, 0, 0, 2, 0x41, 0x01]))
                let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(interFrame, createIfNecessary: false) as? [[CFString: Any]])
                XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool, true)
                var wrong = config; wrong.width = 320
                XCTAssertThrowsError(try factory.configure(wrong)) { XCTAssertEqual($0 as? WireError, .invalidVideo) }
                XCTAssertThrowsError(try factory.sample(data))
                try factory.configure(config)
                factory.reset()
                XCTAssertThrowsError(try factory.sample(data))
            } catch { XCTFail("Configuration check: \(error)") }
            checked.fulfill()
        }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0x50, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        encoder.encode(image, time: CMTime(value: 1, timescale: 30)); encoder.finish()
        wait(for: [checked], timeout: 10)
    }
}
