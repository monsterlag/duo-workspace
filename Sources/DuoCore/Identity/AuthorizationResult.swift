import Foundation

public struct AuthorizationResult: Codable, Sendable {
    public enum State: String, Codable, Sendable { case pending, approved, denied, revoked, busy }
    public let state: State
    public let message: String
    public var supportsAdaptiveDisplay: Bool?
    public var supportsMaximumDetail: Bool?
    public var supportsClipboard: Bool?
    public var supportsAudio: Bool?
    public var supportsMacAudioMute: Bool?
    public var supportsFileTransfer: Bool?
    public var supportsNativeTouch: Bool?
    public var supportsFunctionModifier: Bool?
    public var supportsMicrophone: Bool?
    public var supportsFrameAcks: Bool?
    public init(_ state: State, message: String, supportsAdaptiveDisplay: Bool? = nil, supportsMaximumDetail: Bool? = nil) {
        self.state = state; self.message = message; self.supportsAdaptiveDisplay = supportsAdaptiveDisplay
        self.supportsMaximumDetail = supportsMaximumDetail
    }
}
