import Foundation
import Testing
import DuoCore
@testable import DuoHost

struct NativeTouchDescriptorTests {
    @Test func occupiedDownReportSetsTipAndTouchValidWithLittleEndianCoordinates() {
        let contact = NativeTouchContact(id: 96, x: 0.25, y: 0.75)
        #expect(NativeTouchDescriptor.contactReport(contact, identifier: 5, isDown: true)
            == [0x03, 0x05, 0x00, 0x20, 0xff, 0x5f])
    }

    @Test func occupiedLiftReportKeepsTouchValidAndIdentifierAfterTipClears() {
        let contact = NativeTouchContact(id: 96, x: 0.25, y: 0.75)
        #expect(NativeTouchDescriptor.contactReport(contact, identifier: 5, isDown: false)
            == [0x02, 0x05, 0x00, 0x20, 0xff, 0x5f])
    }

    @Test func contactReportClampsCoordinateRangeAndRoundsHalfwayValues() {
        #expect(NativeTouchDescriptor.contactReport(.init(id: 1, x: -0.5, y: 1.5),
                                                   identifier: 1, isDown: true)
            == [0x03, 0x01, 0x00, 0x00, 0xff, 0x7f])
        #expect(NativeTouchDescriptor.contactReport(.init(id: 1, x: 0.5, y: 0.5),
                                                   identifier: 1, isDown: false)
            == [0x02, 0x01, 0x00, 0x40, 0x00, 0x40])
    }

    @Test func eachFingerDeclaresTouchValidBesideTipSwitchWithoutChangingPayloadSize() {
        let fingers = fingerInputs(Array(NativeTouchDescriptor.descriptor()))
        #expect(fingers.count == 5)
        for fields in fingers {
            #expect(Array(fields.prefix(3)) == [
                HIDInput(page: 0x0d, usage: 0x42, offset: 0, width: 1, constant: false),
                HIDInput(page: 0x0d, usage: 0x47, offset: 1, width: 1, constant: false),
                HIDInput(page: nil, usage: nil, offset: 2, width: 6, constant: true)
            ])
            #expect(fields.reduce(0) { $0 + $1.width } == 48)
        }
    }

    @Test func fiveContactReportKeepsItsHIDLayout() {
        let descriptor = Array(NativeTouchDescriptor.descriptor())
        var offset = 0, reportID: UInt8 = 0, size = 0, count = 0
        var inputBits: [UInt8: Int] = [:], featureBits: [UInt8: Int] = [:]
        while offset < descriptor.count {
            let prefix = descriptor[offset]
            let length = [0, 1, 2, 4][Int(prefix & 3)]
            let payload = descriptor[(offset + 1)..<(offset + 1 + length)]
            let value = payload.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            switch prefix & 0xfc {
            case 0x74: size = value
            case 0x94: count = value
            case 0x84: reportID = UInt8(value)
            case 0x80: inputBits[reportID, default: 0] += size * count
            case 0xb0: featureBits[reportID, default: 0] += size * count
            default: break
            }
            offset += 1 + length
        }
        #expect(inputBits == [1: 248])
        #expect(featureBits == [2: 8])
        #expect(Array(descriptor.suffix(11)) == [0x85, 0x02, 0x09, 0x55, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, 0xC0])
    }

    private struct HIDInput: Equatable {
        let page: Int?
        let usage: Int?
        let offset: Int
        let width: Int
        let constant: Bool
    }

    private func fingerInputs(_ descriptor: [UInt8]) -> [[HIDInput]] {
        var fingers: [[HIDInput]] = []
        var offset = 0, page = 0, size = 0, count = 0, depth = 0
        var usages: [Int] = []
        var fingerDepth: Int?
        var bit = 0
        while offset < descriptor.count {
            let prefix = descriptor[offset]
            let length = [0, 1, 2, 4][Int(prefix & 3)]
            let payload = descriptor[(offset + 1)..<(offset + 1 + length)]
            let value = payload.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            switch prefix & 0xfc {
            case 0x04: page = value
            case 0x08: usages.append(value)
            case 0x74: size = value
            case 0x94: count = value
            case 0xa0:
                depth += 1
                if page == 0x0d && usages.last == 0x22 {
                    fingerDepth = depth; bit = 0; fingers.append([])
                }
            case 0xc0:
                if fingerDepth == depth { fingerDepth = nil }
                depth -= 1
            case 0x80:
                if fingerDepth != nil {
                    if value & 1 != 0 {
                        fingers[fingers.count - 1].append(HIDInput(page: nil, usage: nil,
                            offset: bit, width: size * count, constant: true))
                    } else {
                        for index in 0..<count {
                            let usage = index < usages.count ? usages[index] : usages.last
                            fingers[fingers.count - 1].append(HIDInput(page: page, usage: usage,
                                offset: bit + index * size, width: size, constant: false))
                        }
                    }
                    bit += size * count
                }
            default: break
            }
            if prefix & 0x0c == 0 { usages.removeAll() }
            offset += 1 + length
        }
        return fingers
    }
}
