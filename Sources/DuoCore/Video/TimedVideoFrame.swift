import Foundation

/// `timedVideoFrame` payload: an 8-byte time, then the access unit. An
/// `identifiedVideoFrame` puts a 4-byte frame ID first, which the client echoes
/// in a `videoFrameAck` once the frame is queued for display.
public struct TimedVideoFrame: Sendable {
    public let id: UInt32?
    public let time: TimeInterval
    public let data: Data
    public init(id: UInt32? = nil, time: TimeInterval, data: Data) { self.id = id; self.time = time; self.data = data }

    public func encoded() -> Data {
        var result = Data()
        if let id { result.append(contentsOf: Self.bytes(id)) }
        var bits = time.bitPattern.bigEndian
        result.append(withUnsafeBytes(of: &bits) { Data($0) })
        result.append(data)
        return result
    }

    public init(encoded: Data, identified: Bool = false) throws {
        let header = identified ? 4 : 0
        guard encoded.count > header + 8 else { throw WireError.invalidVideo }
        id = identified ? encoded.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } : nil
        let bits = encoded.dropFirst(header).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        time = Double(bitPattern: bits)
        guard time.isFinite, time >= 0 else { throw WireError.invalidVideo }
        data = Data(encoded.dropFirst(header + 8))
    }

    /// `videoFrameAck` payload: the newest enqueued 4-byte big-endian frame ID, which
    /// covers every earlier frame, then a 2-byte count of milliseconds the client held it.
    public static func acknowledgement(_ id: UInt32, heldMilliseconds: Int = 0) -> Data {
        let held = UInt16(clamping: max(0, heldMilliseconds))
        return Data(bytes(id) + [UInt8(held >> 8), UInt8(held & 255)])
    }

    public static func acknowledged(_ payload: Data) throws -> (id: UInt32, held: TimeInterval) {
        guard payload.count == 6 else { throw WireError.invalidVideo }
        let id = payload.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let held = payload.suffix(2).reduce(0) { ($0 << 8) | Int($1) }
        return (id, Double(held) / 1000)
    }

    private static func bytes(_ id: UInt32) -> [UInt8] { (0..<4).map { UInt8((id >> (24 - 8 * $0)) & 255) } }
}
