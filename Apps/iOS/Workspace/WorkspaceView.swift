import SwiftUI
import Observation
import DuoCore

struct WorkspaceView: View {
    let model: SessionModel
    let viewportContext: WorkspaceViewportContext
    var revealControls: (() -> Void)?

    @Environment(\.localZoom) private var zoom

    var body: some View {
        ZStack {
            ZStack {
                Color.black
                SampleVideoView(renderer: model.renderer, isActive: model.display.viewportContext == viewportContext,
                                isCurrentContext: { model.display.viewportContext == viewportContext }) {
                    model.display.reportViewport($0, display: $1, context: viewportContext)
                }
                    .scaleEffect(zoom?.value.scale ?? 1, anchor: .topLeading)
                    .offset(x: zoom?.value.offset.x ?? 0, y: zoom?.value.offset.y ?? 0)
                    .accessibilityHidden(true)
                PointerSurface(input: model.input, enabled: model.canSendInput,
                               mode: model.workspacePointerMode, frameAspect: model.frameAspect,
                               nativeTouch: model.nativeTouch,
                               nativeTouchCancellationID: model.nativeTouch.cancellationID,
                               doubleTapAction: model.settings.touchDoubleTapAction, revealControls: revealControls,
                               accessibleName: "Mac desktop pointer",
                               zoom: model.workspacePointerMode == .nativeTouch ? nil : zoom)
            }
            .clipped()
            .ignoresSafeArea(.container)
            // The keyboard or a fold layout change resizes the view; keep the zoom on the same spot.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                zoom?.value.layout(in: CGRect(origin: .zero, size: size), aspect: model.frameAspect)
            }
            if model.state != .connected { ConnectionOverlay(model: model) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac workspace")
    }
}

/// The session's local zoom of the Mac picture, owned above the workspace layouts
/// so a canvas or tabletop switch keeps it.
@MainActor @Observable
final class LocalZoomState {
    var value = LocalZoom()
}

extension EnvironmentValues {
    @Entry var localZoom: LocalZoomState?
}
