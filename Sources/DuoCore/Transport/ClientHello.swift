public struct ClientHello: Codable, Sendable {
    public var version: Int = 1
    public var mode: WorkspaceMode
    public var width: Int
    public var height: Int
    public var quality: StreamQuality?
    public var desktop: DesktopSize?
    public var supportsCaptureRecovery: Bool?
    public var supportsMediaTiming: Bool?
    /// Echo each `identifiedVideoFrame` with a `videoFrameAck`; only sent when the host offers it.
    public var supportsFrameAcks: Bool?
    public init(mode: WorkspaceMode, width: Int, height: Int, quality: StreamQuality? = nil, desktop: DesktopSize? = nil,
                supportsCaptureRecovery: Bool? = nil) {
        self.mode=mode; self.width=width; self.height=height; self.quality=quality; self.desktop=desktop
        self.supportsCaptureRecovery = supportsCaptureRecovery
        version = desktop == nil ? 1 : 2
    }
    public var isValid: Bool {
        if let desktop {
            guard version == 2, mode == .extend, desktop.isValid, let quality else { return false }
            let stream = StreamDimensions.forDesktop(desktop, quality: quality)
            return width == stream.width && height == stream.height
        }
        return version == 1 && (320...3840).contains(width) && (240...2160).contains(height)
            && VideoRasterLimits.contains(width: width, height: height)
            && (quality == nil || (width == quality?.width && height == quality?.height))
    }
}
