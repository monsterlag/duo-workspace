import Foundation

public enum MessageKind: UInt8, Sendable {
    case hello=1, status, videoConfiguration, videoFrame, input, ping, pong, authorize, authorization, resizeDesktop, desktopState
    case clipboardRequest, clipboardResponse
    case audioFrame, audioControl, audioStatus, timedVideoFrame
    case fileTransfer
    case nativeTouchControl, nativeTouchStatus, nativeTouchFrame
    case microphoneControl, microphoneStatus, microphoneFrame
    case identifiedVideoFrame, videoFrameAck
}
public struct Packet: Sendable {
    public var kind: MessageKind
    public var sequence: UInt64
    public var payload: Data
    /// Uptime when the channel decoded the packet, before it waits behind earlier handlers.
    public var receivedAt: TimeInterval = 0
    public init(kind: MessageKind, sequence: UInt64, payload: Data) { self.kind=kind; self.sequence=sequence; self.payload=payload }
    public func encoded() throws -> Data {
        guard payload.count <= PacketDecoder.maximumPayload else { throw WireError.oversized }
        var out=Data([1,kind.rawValue,0,0])
        for n in [UInt64(payload.count)] { for shift in stride(from:24,through:0,by:-8) { out.append(UInt8((n >> shift) & 255)) } }
        for shift in stride(from:56,through:0,by:-8) { out.append(UInt8((sequence >> shift) & 255)) }
        out.append(payload); return out
    }
}
public enum WireError: Error, Equatable { case version, kind, reserved, oversized, replay, invalidVideo }
public struct PacketDecoder {
    public static let maximumPayload = 8 * 1024 * 1024
    private var buffer=Data()
    private var lastSequence: UInt64?
    private let payloadLimit: Int
    public init(maximumPayload: Int = Self.maximumPayload) { payloadLimit = min(Self.maximumPayload, max(0, maximumPayload)) }
    public mutating func append(_ data: Data) throws -> [Packet] {
        buffer.append(data)
        var packets=[Packet]()
        while buffer.count >= 16 {
            let h=Array(buffer.prefix(16))
            guard h[0] == 1 else { throw WireError.version }
            guard let kind=MessageKind(rawValue:h[1]) else { throw WireError.kind }
            guard h[2] == 0 && h[3] == 0 else { throw WireError.reserved }
            let length=h[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= payloadLimit else { throw WireError.oversized }
            guard buffer.count >= 16+length else { break }
            let seq=h[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if let lastSequence, seq <= lastSequence { throw WireError.replay }
            lastSequence=seq
            packets.append(Packet(kind:kind,sequence:seq,payload:Data(buffer.dropFirst(16).prefix(length))))
            buffer.removeFirst(16+length)
        }
        return packets
    }
}
