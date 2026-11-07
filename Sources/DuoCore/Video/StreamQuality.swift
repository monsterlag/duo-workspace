import Foundation

public enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case efficient, balanced, sharp, maximum

    public var width: Int {
        switch self { case .efficient: 1280; case .balanced: 1600; case .sharp: 1920; case .maximum: 3000 }
    }

    public var height: Int { self == .maximum ? 2000 : width * 5 / 8 }
    public var framesPerSecond: Int { 60 }
    /// The ceiling for adaptive bitrate.
    public var bitRate: Int {
        switch self { case .efficient: 3_000_000; case .balanced: 6_000_000; case .sharp: 10_000_000; case .maximum: 20_000_000 }
    }
}
