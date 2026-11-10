import SwiftUI
import AVFoundation
import Testing
import DuoCore
@testable import DuoWorkspace

@MainActor
struct WorkspaceInterfaceTests {
    @Test func sceneActivationRestoresTheVideoSurfaceWithoutAnotherLayout() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let renderer = VideoRenderer()
        let surface = VideoSurface(renderer: renderer)
        let window = UIWindow(windowScene: scene)
        defer { withExtendedLifetime(window) {} }
        surface.isActiveSurface = true
        surface.isCurrentContext = { true }
        surface.onViewport = { _, _ in }
        window.addSubview(surface)
        surface.reportViewport()
        #expect(renderer.activeLayer === surface.videoLayer)

        // A background viewport update detaches the surface. Becoming active
        // must restore it even when neither its bounds nor its controls change.
        renderer.detach(surface.videoLayer)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(renderer.activeLayer === surface.videoLayer)

        renderer.detach(surface.videoLayer)
        surface.isCurrentContext = { false }
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(renderer.activeLayer == nil)
    }

    @Test func retiredLayerCannotReplaceTheCurrentVideoSurface() {
        let renderer = VideoRenderer()
        let old = AVSampleBufferDisplayLayer(), current = AVSampleBufferDisplayLayer()
        var selected = 1
        renderer.attach(old) { selected == 1 }
        selected = 2
        renderer.attach(current) { selected == 2 }
        renderer.attach(old) { selected == 1 }
        #expect(renderer.activeLayer === current)
        renderer.detach(old)
        #expect(renderer.activeLayer === current)
    }

    @Test func bookFoldDoesNotReserveAnEmptyKeyboardPane() {
        let book = CGRect(x: 470, y: 0, width: 12, height: 680)
        for keyboard in [false, true] {
            for software in [false, true] {
                #expect(!WorkspaceLayoutPolicy.usesTabletopPanes(division: book, keyboardMode: keyboard,
                                                                softwareKeyboardVisible: software))
            }
        }
    }

    @Test func tabletopUsesLowerPaneOnlyWhenItHasControls() {
        let tabletop = CGRect(x: 0, y: 450, width: 680, height: 12)
        #expect(WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: false, softwareKeyboardVisible: false))
        #expect(WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: true, softwareKeyboardVisible: true))
        #expect(WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: true, softwareKeyboardVisible: false))
        #expect(!WorkspaceLayoutPolicy.usesTabletopPanes(division: nil, keyboardMode: true, softwareKeyboardVisible: false))
        #expect(!WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: false, softwareKeyboardVisible: false, inputEnabled: false))
        #expect(!WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: false, softwareKeyboardVisible: false, controlsVisible: false))
        #expect(!WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: false, softwareKeyboardVisible: false, lowerPaneCanFitControls: false))
    }

    @Test func measuredKeyboardGeometryDoesNotLeaveAStaleEmptyPane() {
        #expect(KeyboardPresentation.measured(occupiedHeight: 0, accessoryHeight: 52) == .hidden)
        let hardware = KeyboardPresentation.measured(occupiedHeight: 52, accessoryHeight: 52)
        #expect(hardware.hasKeyboardUI && !hardware.hasSoftwareKeys)
        #expect(KeyboardPresentation.measured(occupiedHeight: 320, accessoryHeight: 52) == .software)
        let hidden = KeyboardPresentation.measured(occupiedHeight: 0, accessoryHeight: 52)
        let tabletop = CGRect(x: 0, y: 450, width: 680, height: 12)
        #expect(WorkspaceLayoutPolicy.usesTabletopPanes(division: tabletop, keyboardMode: true,
                                                       softwareKeyboardVisible: hidden.hasSoftwareKeys))
    }

    @Test func tabletopKeyboardDismissalKeepsTheDisplayAboveUsableControls() {
        let fold = CGRect(x: 0, y: 450, width: 680, height: 12)
        for presentation in [KeyboardPresentation.software, .hidden, .accessory, .hidden, .software] {
            #expect(WorkspaceLayoutPolicy.usesTabletopPanes(division: fold, keyboardMode: true,
                                                           softwareKeyboardVisible: presentation.hasSoftwareKeys))
        }
        #expect(!WorkspaceLayoutPolicy.showsTabletopTrackpad(availableHeight: 0, minimumHeight: 212))
        #expect(WorkspaceLayoutPolicy.showsTabletopTrackpad(availableHeight: 400, minimumHeight: 212))
        #expect(!WorkspaceLayoutPolicy.showsTabletopTrackpad(availableHeight: .nan, minimumHeight: 212))
        #expect(!WorkspaceLayoutPolicy.usesTabletopPanes(division: fold, keyboardMode: true,
                                                        softwareKeyboardVisible: false, lowerPaneCanFitControls: false))
    }

    @Test func otherKeyboardUICannotSuppressThisSessionsControls() {
        #expect(KeyboardPresentation.software.forSession(keyboardMode: false, focusRequested: false) == .hidden)
        #expect(KeyboardPresentation.software.forSession(keyboardMode: true, focusRequested: false) == .hidden)
        #expect(KeyboardPresentation.software.forSession(keyboardMode: true, focusRequested: true) == .software)
    }

    @Test func dockAvoidsCornerCameraWithoutMovingToTheTop() throws {
        let area = CGRect(x: 10, y: 10, width: 658, height: 446)
        let camera = CGRect(x: 590, y: 370, width: 80, height: 100)
        let frame = try #require(SessionControlPlacement.frame(in: area, size: CGSize(width: 540, height: 100),
            avoiding: [camera], trailing: true, preferredOrigin: CGPoint(x: 69, y: 356)))
        #expect(area.contains(frame))
        #expect(!camera.intersects(frame))
        #expect(frame.minY > area.midY)
    }

    @Test func sessionControlAvoidsReservedRegions() throws {
        let area = CGRect(x: 8, y: 8, width: 680, height: 430)
        let arrangements: [[CGRect]] = [
            [CGRect(x: 605, y: 0, width: 90, height: 110)],
            [CGRect(x: 0, y: 0, width: 80, height: 100)],
            [CGRect(x: 0, y: 0, width: 700, height: 100)],
            [CGRect(x: 330, y: 0, width: 40, height: 460), CGRect(x: 600, y: 0, width: 100, height: 90)]
        ]
        for blocked in arrangements {
            for trailing in [false, true] {
                for size in [CGSize(width: 60, height: 60), CGSize(width: 128, height: 60)] {
                    let frame = try #require(SessionControlPlacement.frame(in: area, size: size,
                                                                           avoiding: blocked, trailing: trailing))
                    #expect(area.contains(frame))
                    #expect(!blocked.contains { $0.intersects(frame) })
                }
            }
        }
    }

    @Test func sessionControlHasNoUnsafePlacementInCoveredArea() {
        let area = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(SessionControlPlacement.frame(in: area, size: CGSize(width: 44, height: 44),
                                              avoiding: [area], trailing: true) == nil)
    }

    @Test func foldReleasePreservesCompositionButEndsHeldInput() throws {
        let name = "WorkspaceInterface.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let input = SessionInputController(settings: AppSettings(defaults: defaults))
        input.composition = "にほん"
        input.modifier(.command)
        input.beginDrag()
        let generation = input.keyboardResetID
        input.releaseHeldInput()
        #expect(input.composition == "にほん")
        #expect(input.keyboardResetID == generation)
        #expect(!input.isDragging && input.modifiers.isEmpty)
        input.releaseAll()
        #expect(input.composition.isEmpty)
        #expect(input.keyboardResetID != generation)
    }

    @Test func canceledMarkedTextCannotCommitDuringResign() throws {
        let name = "WorkspaceInterface.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let input = SessionInputController(settings: AppSettings(defaults: defaults))
        var emitted: [InputEvent] = []
        input.emit = { emitted.append($0) }
        let coordinator = RemoteKeyboardField.Coordinator(input: input, focused: .constant(true))
        let field = UITextField()
        field.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        #expect(field.markedTextRange != nil)
        coordinator.changed(field)
        #expect(input.composition == "にほん")
        #expect(emitted.compactMap(\.text).isEmpty)
        input.releaseAll()
        // A queued editing callback can arrive before updateUIView sees reset.
        coordinator.changed(field)
        #expect((field.text ?? "").isEmpty)
        #expect(field.markedTextRange == nil)
        #expect(emitted.compactMap(\.text).isEmpty)
        field.text = "fresh"
        coordinator.changed(field)
        #expect(emitted.compactMap(\.text) == ["fresh"])
    }
}
