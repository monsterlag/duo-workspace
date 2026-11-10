import SwiftUI
import DuoCore

struct RemoteSessionView: View {
    let model: SessionModel
    @State private var keyboard = false
    @State private var keyboardFocused = false
    @State private var keyboardPresentation = KeyboardPresentation.hidden
    @State private var presentation = SessionPresentation()
    @State private var chrome = WorkspaceChrome()
    @State private var requestedKeyboardControls = KeyboardControlsOwner.inputAccessory
    @State private var keyboardControlsOwner = KeyboardControlsOwner.inputAccessory
    @State private var zoom = LocalZoomState()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sessionKeyboard: KeyboardPresentation {
        keyboardPresentation.forSession(keyboardMode: keyboard, focusRequested: keyboardFocused)
    }

    var body: some View {
        @Bindable var panels = presentation
        ZStack {
            if #available(iOS 27.1, *) {
                FoldWorkspace(model: model, keyboard: $keyboard, keyboardFocused: $keyboardFocused,
                              keyboardPresentation: sessionKeyboard, chrome: chrome,
                              showSession: showSession, hideControls: hideControls,
                              keyboardControlsOwner: keyboardControlsOwner,
                              prefersNativeKeyboardControls: dynamicTypeSize.isAccessibilitySize || voiceOverEnabled || switchControlEnabled,
                              keyboardControlsRequested: { requestedKeyboardControls = $0 })
                    .onHingeChange { _, _ in model.input.releaseHeldInput() }
                    .ignoresSafeArea(.container)
            } else {
                GeometryReader { geometry in
                    let context = WorkspaceViewportContext(rootSize: geometry.size, layout: .canvas,
                                                           keyboardMode: keyboard, keyboardPresentation: sessionKeyboard)
                    KeyboardAvoidingRegion {
                        FlatWorkspace(model: model, viewportContext: context, keyboard: $keyboard, keyboardFocused: $keyboardFocused,
                                      nativeKeyboardVisible: keyboardControlsOwner.hasVisibleAccessory(for: sessionKeyboard),
                                      chrome: chrome, showSession: showSession, hideControls: hideControls)
                    }
                    .onChange(of: context, initial: true) { model.display.selectViewport(context) }
                }
                .ignoresSafeArea(.container)
            }
        }
        .environment(\.localZoom, zoom)
        .overlay {
            ControlsEdgeHints(visible: !chrome.isVisible && model.state == .connected)
                .ignoresSafeArea(.container, edges: .horizontal)
        }
        .overlay(alignment: .topLeading) {
            // Keep the text field in place so folding preserves marked text.
            RemoteKeyboardField(input: model.input, focused: $keyboardFocused, keyboard: $keyboard,
                                enabled: model.canControl && model.hasVideo,
                                controlsEnabled: model.canSendInput,
                                softwareKeyboardVisible: keyboardPresentation.hasSoftwareKeys,
                                requestedControlsOwner: requestedKeyboardControls,
                                controlsOwnerChanged: { keyboardControlsOwner = $0 },
                                showSession: showSession)
                .frame(width: 1, height: 1).opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(!keyboard)
        }
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                KeyboardPresenceProbe { keyboardPresentation = $0 }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.dark)
        // Each region handles keyboard avoidance without moving the fold.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .modifier(SessionStatusBar())
        .defersSystemGestures(on: model.state == .connected ? .bottom : [])
        .onAppear(perform: updateIdleTimer)
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; model.releaseInput() }
        .onChange(of: model.settings.keepAwake, updateIdleTimer)
        .onChange(of: model.settings.desktopShape) { model.display.refreshDesktopShape() }
        .onChange(of: model.settings.desktopSizing) { model.display.refreshDesktopSizing() }
        .onChange(of: model.settings.pointerMode, initial: true) { model.updateNativeTouch() }
        .onChange(of: keyboardFocused) { _, focused in if !focused { model.releaseInput() } }
        .onChange(of: keyboard) { _, enabled in model.releaseInput(); keyboardFocused = enabled }
        .sheet(item: $panels.sheet, onDismiss: didDismissPanel) { sheet in
            SessionPanelView(sheet: sheet, model: model, close: presentation.dismiss,
                             hideControls: hideControls, chooseFileOnMac: chooseFileOnMac)
                .id(sheet.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: presentation.sheet?.id) { _, sheet in
            if sheet != nil { model.releaseInput(); keyboardFocused = false }
        }
        .onChange(of: model.files.transfer.state, initial: true) { _, state in
            presentation.fileOfferChanged(available: state == .awaitingAcceptance)
        }
        .onChange(of: model.presentsSession) { _, presented in
            if !presented { presentation.reset() }
        }
        .onChange(of: model.state) { _, state in
            if state != .connected { keyboard = false; keyboardFocused = false; chrome.show(); zoom.value.reset() }
        }
        // Native touch maps contacts without the zoom; a new picture or session starts at fit.
        .onChange(of: model.workspacePointerMode) { _, mode in if mode == .nativeTouch { zoom.value.reset() } }
        .onChange(of: model.active?.id) { zoom.value.reset() }
        .onChange(of: model.display.mode) { zoom.value.reset() }
        .onChange(of: model.frameAspect) { zoom.value.reset() }
        .onChange(of: model.display.desktop) { zoom.value.reset() }
    }

    private func showSession() {
        model.releaseInput(); keyboardFocused = false
        presentation.showSession()
    }

    private func hideControls() {
        model.releaseInput(); keyboard = false; keyboardFocused = false
        chrome.hide(reduceMotion: reduceMotion)
    }

    private func chooseFileOnMac() {
        model.releaseInput(); keyboard = false; keyboardFocused = false
        chrome.show()
        presentation.chooseFileOnMac()
    }

    private func didDismissPanel() {
        guard model.presentsSession else { presentation.reset(); return }
        switch presentation.didDismiss() {
        case .none: break
        case .chooseFileOnMac:
            if !model.files.chooseOnMac() { presentation.showFiles() }
        }
    }

    private func updateIdleTimer() { UIApplication.shared.isIdleTimerDisabled = model.settings.keepAwake }
}
