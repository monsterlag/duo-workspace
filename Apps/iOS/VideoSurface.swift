import SwiftUI
import AVFoundation
import DuoCore

/// Retains a bounded GOP so replacement surfaces can decode from a keyframe.
@MainActor final class VideoRenderer {
    private(set) weak var activeLayer:AVSampleBufferDisplayLayer?
    private var frames=[CMSampleBuffer]()
    private var bytes=0
    private let maximumBytes=8*1024*1024

    func attach(_ layer:AVSampleBufferDisplayLayer, ifCurrent: () -> Bool) {
        guard ifCurrent() else { detach(layer); return }
        guard activeLayer !== layer else{return}
        activeLayer=layer;layer.videoGravity = .resizeAspect
        layer.flushAndRemoveImage()
        for sample in frames {layer.enqueue(sample)}
    }
    func detach(_ layer:AVSampleBufferDisplayLayer) {if activeLayer === layer {activeLayer=nil}}
    func enqueue(_ sample:CMSampleBuffer) {
        let count=CMSampleBufferGetTotalSampleSize(sample)
        let keyframe=Self.isKeyframe(sample)
        if keyframe {frames.removeAll(keepingCapacity:true);bytes=0}
        if !frames.isEmpty || keyframe {
            if bytes+count<=maximumBytes && frames.count<120 {frames.append(sample);bytes += count}
            else {frames.removeAll(keepingCapacity:true);bytes=0}
        }
        if activeLayer?.status == .failed {
            activeLayer?.flush()
            for frame in frames {activeLayer?.enqueue(frame)}
        } else {activeLayer?.enqueue(sample)}
    }
    func clear() {frames.removeAll();bytes=0;activeLayer?.flushAndRemoveImage()}
    private static func isKeyframe(_ sample:CMSampleBuffer)->Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

final class VideoSurface:UIView {
    override class var layerClass:AnyClass {AVSampleBufferDisplayLayer.self}
    var videoLayer:AVSampleBufferDisplayLayer {layer as! AVSampleBufferDisplayLayer}
    let renderer:VideoRenderer
    var isActiveSurface = false
    var isCurrentContext: (() -> Bool)?
    var onViewport: ((CGSize, NativeDisplayInfo) -> Void)?
    private var reportGeneration = 0
    init(renderer:VideoRenderer) {
        self.renderer=renderer;super.init(frame:.zero)
        videoLayer.videoGravity = .resizeAspect
        isAccessibilityElement=true;accessibilityLabel="Mac workspace"
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate),
                                               name: UIScene.didActivateNotification, object: nil)
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = window?.windowScene, notification.object as? UIWindowScene === scene else { return }
        reportViewport()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportViewport()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        reportViewport()
    }

    func reportViewport() {
        reportGeneration &+= 1
        let generation = reportGeneration
        guard isActiveSurface, isCurrentContext?() == true, let scene = window?.windowScene,
              scene.activationState != .background, scene.activationState != .unattached,
              let callback = onViewport else { renderer.detach(videoLayer); return }
        renderer.attach(videoLayer) { self.isCurrentContext?() == true }
        let viewport = bounds.size
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width >= 80, viewport.height >= 80 else { return }
        let screen = scene.screen
        let native = screen.nativeBounds.size
        guard native.width.isFinite, native.height.isFinite, (1...16_384).contains(native.width),
              (1...16_384).contains(native.height) else { return }
        // Full-panel pixel detection uses screen points; layout uses local bounds.
        let points = screen.bounds.size
        let info = NativeDisplayInfo(pixels: DisplayPixelSize(width: Int(native.width), height: Int(native.height)),
                                     pointWidth: points.width, pointHeight: points.height, nativeScale: screen.nativeScale)
        guard info.isValid else { return }
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let scene, self?.window?.windowScene === scene,
                  self?.isActiveSurface == true, self?.reportGeneration == generation,
                  self?.isCurrentContext?() == true,
                  scene.activationState != .background, scene.activationState != .unattached else { return }
            callback(viewport, info)
        }
    }
}
struct SampleVideoView:UIViewRepresentable {
    let renderer:VideoRenderer
    let isActive: Bool
    var isCurrentContext: () -> Bool
    var onViewport: (CGSize, NativeDisplayInfo) -> Void
    func makeUIView(context:Context)->VideoSurface {VideoSurface(renderer:renderer)}
    func updateUIView(_ view:VideoSurface,context:Context) {
        view.isActiveSurface = isActive
        view.isCurrentContext = isCurrentContext
        view.onViewport = onViewport
        view.reportViewport()
    }
    static func dismantleUIView(_ view:VideoSurface,coordinator:()) {
        view.isActiveSurface = false; view.isCurrentContext = nil; view.onViewport = nil; view.reportViewport()
    }
}
