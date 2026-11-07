import Foundation
import Observation
import Network
import AppKit
import DuoCore

@MainActor @Observable
public final class HostController {
    public private(set) var status = "Stopped"
    public private(set) var receivedInputCount = 0
    public private(set) var lastInputKind = "None"
    public private(set) var inputDiagnostics = "No input yet"
    public private(set) var sharing = false
    public private(set) var activeDisplayID = CGMainDisplayID()
    public private(set) var captureAllowed = false
    public private(set) var inputAllowed = false
    public let access: DeviceAccessController
    public let microphone = HostMicrophone()
    public private(set) var listeningPort: UInt16?
    @ObservationIgnored private let port: UInt16
    @ObservationIgnored private let loopbackOnly: Bool
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var channel: SecureChannel?
    @ObservationIgnored private var connections: [UUID: HostConnection] = [:]
    @ObservationIgnored private var pipeline: HostMediaPipeline?
    @ObservationIgnored private var mediaConfiguration: HostMediaPipeline.Configuration?
    @ObservationIgnored private var virtual: VirtualDisplayHandle?
    @ObservationIgnored private let input = InputInjector()
    @ObservationIgnored private var nativeTouchNegotiated = false
    @ObservationIgnored private lazy var nativeTouch = NativeTouchController(allowed: { [weak self] in
        guard let self, self.activeAllowsControl, self.canReceiveInput, AXIsProcessTrusted(),
              let session = self.connections.values.first(where: { $0.channel === self.channel }),
              let pin = session.peerPin else { return false }
        return self.authorized(session) && self.access.approvedDevice(pin: pin)?.allowsControl == true
    })
    @ObservationIgnored private let wake = SessionWakeAssertion()
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var canReceiveInput = false
    @ObservationIgnored private var activeAllowsControl = false
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var admission = AdmissionLimiter()
    @ObservationIgnored private var pipelineGeneration: UInt64 = 0
    @ObservationIgnored private var streamMode: WorkspaceMode?
    @ObservationIgnored private var streamQuality = StreamQuality.balanced
    @ObservationIgnored private var currentDesktop: DesktopSize?
    @ObservationIgnored private var currentDesktopRevision: UInt64 = 0
    @ObservationIgnored private var currentDesktopAccepted = true
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: DesktopResizeRequest?
    @ObservationIgnored private var lastResizeRevision: UInt64 = 0
    @ObservationIgnored private var deferredInput = DeferredInputBuffer()
    @ObservationIgnored private var replayingInput = false
    @ObservationIgnored private var activeResize: DesktopResizeRequest?
    @ObservationIgnored private var captureRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var captureRecoveryBudget = CaptureRecoveryBudget()
    @ObservationIgnored private var recoveryFailure: CaptureFailure?
    @ObservationIgnored private var failedCaptureGeneration: UInt64?
    @ObservationIgnored private var supportsCaptureRecovery = false
    @ObservationIgnored private var acknowledgesFrames = false
    @ObservationIgnored private let audio = HostAudioStream()
    @ObservationIgnored private var microphoneNegotiated = false
    #if DEBUG
    @ObservationIgnored private var captureFaults: DebugCaptureFaults?
    @ObservationIgnored private var interruptNextResize = false
    @ObservationIgnored private var interruptNextCaptureStart = false
    #endif

    public convenience init() { self.init(access: DeviceAccessController(), port: 47991, loopbackOnly: false) }

    init(access: DeviceAccessController, port: UInt16, loopbackOnly: Bool) {
        self.access = access; self.port = port; self.loopbackOnly = loopbackOnly
        refreshPermissions()
        access.onDecision = { [weak self] id, result in self?.finishAuthorization(id, result: result) }
        access.onRevoke = { [weak self] id in self?.revokeConnections(deviceID: id) }
        access.onStorageFailure = { [weak self] in self?.stop() }
        microphone.changed = { [weak self] status in
            guard let self, self.microphoneNegotiated else { return }
            self.channel?.send(.microphoneStatus, object: status)
        }
        nativeTouch.onStatus = { [weak self] value in
            guard let self, self.nativeTouchNegotiated else { return }
            self.input.nativeTouchActive = value.state == .ready
            if value.state != .ready { self.input.releaseAll() }
            self.channel?.send(.nativeTouchStatus, object: value)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--capture-recovery-testing") {
            captureFaults = DebugCaptureFaults(armResize: { [weak self] in
                guard let self else { return }
                if self.streamMode == nil {
                    self.interruptNextCaptureStart = true
                    self.trace("armed initial capture interruption")
                } else {
                    self.interruptNextResize = true
                    self.trace("armed resize interruption")
                }
            }) { [weak self] failure in
                guard let self, let channel = self.channel, self.streamMode != nil, self.mediaConfiguration != nil else { return }
                self.captureFailed(failure, transport: channel, generation: self.pipelineGeneration)
            }
        }
        #endif
    }

    public func refreshPermissions() {
        captureAllowed = CGPreflightScreenCaptureAccess()
        inputAllowed = AXIsProcessTrusted()
        Task { await microphone.refresh() }
    }
    public func installMicrophone() {
        guard let package = Bundle.main.url(forResource: "DuoMicrophone", withExtension: "pkg") else { return }
        NSWorkspace.shared.open(package)
    }
    public func requestCapture() { _ = CGRequestScreenCaptureAccess(); refreshPermissions() }
    public func requestInput() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refreshPermissions()
    }

    public func start() {
        guard access.isReady, let identity = access.identity, listener == nil else { return }
        captureRecoveryBudget = CaptureRecoveryBudget()
        refreshPermissions()
        do {
            let next = try NWListener(using: SecureParameters.server(identity: identity, loopbackOnly: loopbackOnly), on: NWEndpoint.Port(rawValue: port) ?? .any)
            next.service = NWListener.Service(name: Host.current().localizedName ?? "Duo Mac", type: "_duoworkspace._tcp")
            next.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            next.stateUpdateHandler = { [weak self, weak next] state in Task { @MainActor in
                guard let self, self.listener === next else { return }
                switch state {
                case .ready: self.status = "Waiting for a paired device"; self.sharing = true; self.listeningPort = next?.port?.rawValue
                case .failed(let error): self.stop(); self.status = error.localizedDescription
                default: break
                }
            } }
            listener = next
            next.start(queue: DispatchQueue(label: "DuoWorkspace.Listener"))
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.expireConnections()
                    await self?.microphone.refresh()
                }
            }
        } catch { status = error.localizedDescription }
    }

    public func stop() {
        listener?.cancel(); listener = nil; watchdog?.cancel()
        access.cancelInvitation()
        for id in Array(connections.keys) { closeConnection(id) }
        disconnect()
        sharing = false; listeningPort = nil; status = "Stopped"
    }

    private func disconnect() {
        microphone.stop(); microphoneNegotiated = false
        nativeTouch.stop(); nativeTouchNegotiated = false
        invalidatePipeline()
        captureRecoveryTask?.cancel(); captureRecoveryTask = nil
        recoveryFailure = nil; failedCaptureGeneration = nil
        activeResize = nil; supportsCaptureRecovery = false; acknowledgesFrames = false
        mediaConfiguration = nil; audio.stop()
        #if DEBUG
        interruptNextResize = false
        interruptNextCaptureStart = false
        #endif
        resizeTask?.cancel(); resizeTask = nil; pendingResize = nil
        currentDesktop = nil; streamMode = nil; lastResizeRevision = 0
        currentDesktopRevision = 0; currentDesktopAccepted = true
        deferredInput.removeAll(); replayingInput = false
        canReceiveInput = false; starting = false; activeAllowsControl = false
        input.reset(); wake.release(); channel = nil
        let previous = pipeline, display = virtual, touch = nativeTouch
        pipeline = nil; virtual = nil
        let previousCleanup = cleanup
        cleanup = Task {
            await previousCleanup?.value
            await touch.waitForRelease()
            await previous?.stop(); display?.close()
        }
        activeDisplayID = CGMainDisplayID()
    }

    private func accept(_ connection: NWConnection) {
        let peer: String
        if case let .hostPort(host, _) = connection.endpoint { peer = String(describing: host) }
        else { peer = "other" }
        guard listener != nil, connections.count < 4,
              admission.allow(peer, now: ProcessInfo.processInfo.systemUptime) else { connection.cancel(); return }
        let transport = SecureChannel(connection, maximumIncomingPayload: 128 * 1024)
        let session = HostConnection(channel: transport)
        connections[session.id] = session
        trace("accepted session=\(session.id)")
        transport.onReadyAsync = { @MainActor [weak self, weak session] in
            guard let self, let session, self.connections[session.id] === session else { return }
            guard session.channel.isTLS13, let pin = session.channel.peerPublicKeyPin else {
                self.closeConnection(session.id); return
            }
            session.peerPin = pin
        }
        transport.onPacketAsync = { @MainActor [weak self, weak session] packet in
            guard let self, let session, self.connections[session.id] === session else { return }
            session.lastMessage = ProcessInfo.processInfo.systemUptime
            await self.receive(packet, from: session)
        }
        transport.onFailure = { [weak self, weak session] _ in Task { @MainActor in
            guard let self, let session else { return }
            self.closeConnection(session.id, reason: "transport ended")
        } }
        transport.start()
    }

    private func receive(_ packet: Packet, from session: HostConnection) async {
        switch packet.kind {
        case .authorize:
            guard !session.authorizationRequested, let pin = session.peerPin ?? session.channel.peerPublicKeyPin,
                  let request = try? JSONDecoder().decode(AuthorizationRequest.self, from: packet.payload), request.isValid else {
                closeConnection(session.id); return
            }
            session.authorizationRequested = true
            session.peerPin = pin
            session.purpose = request.purpose ?? .workspace
            if session.purpose == .files {
                guard access.approvedDevice(pin: pin)?.allowsControl == true,
                      connections.values.contains(where: { $0.channel === channel && $0.authorized && $0.peerPin == pin }) else {
                    finishAuthorization(session.id, result: AuthorizationResult(.denied, message: "Start a workspace with control access before transferring files.")); return
                }
            }
            guard let hostPin = access.identity?.publicKeyPin,
                  let code = session.channel.pairingVerificationCode(hostPin: hostPin, devicePin: pin) else { closeConnection(session.id); return }
            let result = access.authorize(pin: pin, request: request, connectionID: session.id, verificationCode: code)
            finishAuthorization(session.id, result: result)
        case .hello:
            guard authorized(session), channel === session.channel, !starting, pipeline == nil,
                  let hello = try? JSONDecoder().decode(ClientHello.self, from: packet.payload), hello.isValid else {
                closeConnection(session.id); return
            }
            starting = true
            await begin(hello, transport: session.channel)
        case .input:
            guard authorized(session), channel === session.channel, activeAllowsControl, inputAllowed,
                  let event = try? JSONDecoder().decode(InputEvent.self, from: packet.payload), event.isValid else { return }
            if event.kind == .releaseAll { nativeTouch.releaseContacts() }
            if captureRecoveryTask != nil {
                if event.kind == .releaseAll { input.releaseAll() }
                return
            }
            if !canReceiveInput {
                guard resizeTask != nil else { return }
                guard deferredInput.append(event, payloadSize: packet.payload.count) else { closeConnection(session.id); return }
                if event.kind == .releaseAll, !replayingInput { input.releaseAll() }
                return
            }
            if event.kind == .keyUp, nativeTouch.requested {
                await nativeTouch.waitForLift()
                guard channel === session.channel, authorized(session), canReceiveInput else { return }
            }
            receivedInputCount += 1; lastInputKind = event.kind.rawValue; input.apply(event)
            let bounds = CGDisplayBounds(input.displayID)
            inputDiagnostics = "Target \(input.keyboardTargetPID ?? 0); display \(input.displayID) at \(Int(bounds.minX)),\(Int(bounds.minY))"
        case .nativeTouchControl:
            guard authorized(session), channel === session.channel, activeAllowsControl, AXIsProcessTrusted(),
                  session.nativeTouchControlBudget.consume(now: ProcessInfo.processInfo.systemUptime),
                  packet.payload.count <= 256,
                  let request = try? JSONDecoder().decode(NativeTouchControl.self, from: packet.payload) else {
                closeConnection(session.id); return
            }
            nativeTouchNegotiated = true
            input.releaseAll()
            await nativeTouch.setEnabled(request.enabled, displayID: activeDisplayID, ready: canReceiveInput)
        case .nativeTouchFrame:
            guard authorized(session), channel === session.channel, activeAllowsControl,
                  nativeTouchNegotiated, packet.payload.count <= 2_048,
                  let frame = try? JSONDecoder().decode(NativeTouchFrame.self, from: packet.payload), frame.isValid else {
                closeConnection(session.id); return
            }
            guard canReceiveInput else { return }
            let beginsGesture = !nativeTouch.hasContacts
            if nativeTouch.receive(frame), let contact = frame.contacts.first {
                input.noteNativeTouch(contact, selectTarget: beginsGesture)
                receivedInputCount += 1; lastInputKind = "nativeTouch"
            }
        case .resizeDesktop:
            guard authorized(session), channel === session.channel, streamMode == .extend, currentDesktop != nil,
                  virtual != nil, let request = try? JSONDecoder().decode(DesktopResizeRequest.self, from: packet.payload),
                  request.isValid, request.revision > lastResizeRevision else { closeConnection(session.id); return }
            lastResizeRevision = request.revision
            pendingResize = request
            startResizeWorker(session)
        case .fileTransfer:
            guard authorized(session), session.purpose == .files, access.approvedDevice(pin: session.peerPin ?? Data())?.allowsControl == true,
                  let files = session.files, let message = try? JSONDecoder().decode(FileTransferMessage.self, from: packet.payload) else {
                closeConnection(session.id); return
            }
            do { try await files.receive(message) }
            catch { closeConnection(session.id) }
        case .microphoneControl:
            guard authorized(session), channel === session.channel,
                  session.microphoneControlBudget.consume(now: ProcessInfo.processInfo.systemUptime), packet.payload.count <= 512,
                  let request = try? JSONDecoder().decode(MicrophoneControl.self, from: packet.payload) else {
                closeConnection(session.id); return
            }
            microphoneNegotiated = true
            let allowed = activeAllowsControl && session.peerPin.flatMap { access.approvedDevice(pin: $0) }?.allowsControl == true
            await microphone.setEnabled(request, allowed: allowed)
        case .microphoneFrame:
            guard authorized(session), channel === session.channel, activeAllowsControl, microphoneNegotiated,
                  session.peerPin.flatMap({ access.approvedDevice(pin: $0) })?.allowsControl == true,
                  packet.payload.count <= 16_384,
                  let frame = try? JSONDecoder().decode(MicrophoneFrame.self, from: packet.payload), frame.isValid else {
                closeConnection(session.id); return
            }
            await microphone.receive(frame)
        case .audioControl:
            guard authorized(session), channel === session.channel, audio.usesMediaTiming,
                  let request = try? JSONDecoder().decode(AudioControl.self, from: packet.payload) else {
                closeConnection(session.id); return
            }
            await audio.apply(request, to: pipeline)
        case .clipboardRequest:
            guard authorized(session), channel === session.channel,
                  session.clipboardBudget.consume(now: ProcessInfo.processInfo.systemUptime),
                  let request = try? JSONDecoder().decode(ClipboardRequest.self, from: packet.payload), request.isValid else {
                closeConnection(session.id); return
            }
            let reply = HostClipboard(pasteboard: .general).handle(request, allowed: activeAllowsControl)
            session.channel.send(.clipboardResponse, object: reply)
        case .videoFrameAck:
            guard authorized(session), channel === session.channel, acknowledgesFrames,
                  let ack = try? TimedVideoFrame.acknowledged(packet.payload) else { closeConnection(session.id); return }
            pipeline?.acknowledge(ack.id, at: packet.receivedAt, held: ack.held)
        case .ping:
            guard packet.payload.count <= 64 else { closeConnection(session.id); return }
            session.channel.send(.pong, payload: packet.payload)
        default: closeConnection(session.id)
        }
    }

    private func authorized(_ session: HostConnection) -> Bool {
        guard session.authorized, let pin = session.peerPin else { return false }
        return access.approvedDevice(pin: pin) != nil
    }

    private func finishAuthorization(_ id: UUID, result: AuthorizationResult) {
        guard let session = connections[id] else { return }
        if result.state == .pending {
            session.waitingApproval = true
            session.channel.send(.authorization, object: result)
        } else if result.state == .approved {
            if session.purpose == .files {
                guard let pin = session.peerPin, access.approvedDevice(pin: pin)?.allowsControl == true,
                      connections.values.contains(where: { $0.channel === channel && $0.authorized && $0.peerPin == pin }),
                      !connections.values.contains(where: { $0 !== session && $0.files != nil }) else {
                    session.channel.send(.authorization, object: AuthorizationResult(.busy, message: "A file connection is already open."))
                    closeConnection(id, gracefully: true); return
                }
                session.authorized = true; session.authorizedAt = ProcessInfo.processInfo.systemUptime
                session.files = HostFileSession(channel: session.channel, displayID: { [weak self] in self?.activeDisplayID ?? CGMainDisplayID() })
                session.channel.send(.authorization, object: result)
                return
            }
            guard channel == nil || channel === session.channel, let pin = session.peerPin,
                  let device = access.approvedDevice(pin: pin) else {
                session.channel.send(.authorization, object: AuthorizationResult(.busy, message: "Your Mac is connected to another device."))
                closeConnection(id, gracefully: true); return
            }
            session.authorized = true; session.waitingApproval = false
            session.authorizedAt = ProcessInfo.processInfo.systemUptime
            session.lastMessage = session.authorizedAt!
            channel = session.channel; activeAllowsControl = device.allowsControl
            var approved = result
            approved.supportsAdaptiveDisplay = true
            approved.supportsMaximumDetail = true
            approved.supportsClipboard = true
            approved.supportsAudio = true
            approved.supportsMacAudioMute = true
            approved.supportsFileTransfer = true
            approved.supportsNativeTouch = NativeTouchController.isSupported
            approved.supportsFunctionModifier = true
            approved.supportsMicrophone = true
            approved.supportsFrameAcks = true
            session.channel.send(.authorization, object: approved)
        } else {
            session.channel.send(.authorization, object: result)
            closeConnection(id, gracefully: true)
        }
    }

    private func closeConnection(_ id: UUID, gracefully: Bool = false, reason: String = "session ended") {
        guard let session = connections.removeValue(forKey: id) else { return }
        trace("closing session=\(id) reason=\(reason)")
        access.cancelRequest(id)
        session.files?.close()
        if channel === session.channel {
            for other in Array(connections.values) where other.purpose == .files { closeConnection(other.id) }
            disconnect(); status = sharing ? "Waiting for a paired device" : "Stopped"
        }
        if gracefully { session.channel.finish() } else { session.channel.cancel() }
    }

    private func closeTransport(_ transport: SecureChannel, gracefully: Bool = false, reason: String = "session ended") {
        guard let id = connections.first(where: { $0.value.channel === transport })?.key else { transport.cancel(); return }
        closeConnection(id, gracefully: gracefully, reason: reason)
    }

    private func revokeConnections(deviceID: String) {
        for session in Array(connections.values) where session.peerPin.map(LocalIdentity.identifier) == deviceID {
            session.channel.send(.authorization, object: AuthorizationResult(.revoked, message: "Your Mac revoked access. Get a new invitation to pair again."))
            closeConnection(session.id, gracefully: true)
        }
    }

    private func expireConnections() {
        access.expirePendingRequests()
        let now = ProcessInfo.processInfo.systemUptime
        for session in Array(connections.values) {
            if session.isExpired(now: now, captureStarted: session.files != nil || (channel === session.channel && pipeline != nil)) {
                trace("watchdog age=\(now - session.lastMessage) reconfiguring=\(session.reconfiguringUntil != nil)")
                closeConnection(session.id, reason: "watchdog expired")
            }
        }
    }

    private func pipelineIsCurrent(_ transport: SecureChannel, generation: UInt64) -> Bool {
        channel === transport && pipelineGeneration == generation
    }

    private func begin(_ hello: ClientHello, transport: SecureChannel) async {
        await cleanup?.value
        guard channel === transport else { return }
        refreshPermissions()
        let capabilities = Capabilities(canCapture: captureAllowed, canControl: inputAllowed && activeAllowsControl,
                                        canCreateDisplay: VirtualDisplayHandle.isAvailable, canPlayAudio: captureAllowed)
        transport.send(.status, object: HostStatus(capabilities: capabilities, message: captureAllowed ? "Starting video" : "Allow screen recording on the Mac"))
        guard captureAllowed else { return }
        invalidatePipeline()
        let generation = pipelineGeneration
        streamMode = hello.mode; streamQuality = hello.quality ?? .balanced
        supportsCaptureRecovery = hello.supportsCaptureRecovery == true
        acknowledgesFrames = hello.supportsFrameAcks == true && hello.supportsMediaTiming == true
        audio.begin(transport: transport, permitsControl: activeAllowsControl, usesMediaTiming: hello.supportsMediaTiming == true)
        do {
            var displayID = CGMainDisplayID()
            var desktop = hello.desktop
            if hello.mode == .extend || displayID == 0 {
                let display = try VirtualDisplayHandle(width: desktop?.width ?? hello.width, height: desktop?.height ?? hello.height,
                                                      scale: desktop?.scale ?? 1)
                virtual = display; displayID = display.displayID
                if let requested = desktop { desktop = try await applyDesktop(requested, to: display) }
                else { try await display.resize(width: hello.width, height: hello.height, scale: 1) }
            }
            guard pipelineIsCurrent(transport, generation: generation) else { return }
            currentDesktop = desktop
            currentDesktopRevision = 0; currentDesktopAccepted = true
            activeDisplayID = displayID; input.displayID = displayID
            input.routesKeyboardToRemoteWindow = hello.mode == .extend
            var dimensions = desktop.map { StreamDimensions.forDesktop($0, quality: streamQuality) }
            // A mismatched aspect ratio adds margins and offsets touch targets.
            if desktop == nil, hello.quality != nil {
                guard let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0, mode.pixelHeight > 0,
                      mode.pixelWidth <= 16_384, mode.pixelHeight <= 16_384 else { throw WireError.invalidVideo }
                dimensions = StreamDimensions.forSource(width: mode.pixelWidth, height: mode.pixelHeight, quality: streamQuality)
            }
            try await startPipeline(displayID: displayID, width: dimensions?.width ?? hello.width, height: dimensions?.height ?? hello.height,
                                    desktop: desktop, transport: transport, generation: generation)
            guard pipelineIsCurrent(transport, generation: generation) else { return }
            canReceiveInput = true; starting = false; wake.acquire()
            await nativeTouch.resume(displayID: displayID)
            guard pipelineIsCurrent(transport, generation: generation) else { return }
            status = hello.mode == .extend ? "Sharing temporary display" : "Sharing existing display"
            if let desktop { transport.send(.desktopState, object: DesktopState(revision: 0, desktop: desktop, ready: true, accepted: true, message: "Connected")) }
            if let session = connections.values.first(where: { $0.channel === transport }) { startResizeWorker(session) }
        } catch {
            guard pipelineIsCurrent(transport, generation: generation) else { return }
            let failure = CaptureFailure(error)
            if failure.canRestartCapture || failure.requiresUserAction {
                captureFailed(failure, transport: transport, generation: generation)
                return
            }
            transport.send(.status, object: HostStatus(capabilities: capabilities, message: error.localizedDescription))
            closeTransport(transport, gracefully: true); status = error.localizedDescription
        }
    }

    private func applyDesktop(_ target: DesktopSize, to display: VirtualDisplayHandle) async throws -> DesktopSize {
        do {
            try await display.resize(width: target.width, height: target.height, scale: target.scale)
            return target
        } catch {
            try Task.checkCancellation()
            guard target.scale == 2 else { throw error }
            let fallback = DesktopSize(width: target.width, height: target.height, scale: 1)
            try await display.resize(width: fallback.width, height: fallback.height, scale: 1)
            return fallback
        }
    }

    private func startPipeline(displayID: CGDirectDisplayID, width: Int, height: Int, desktop: DesktopSize?,
                               transport: SecureChannel, generation: UInt64) async throws {
        guard pipelineIsCurrent(transport, generation: generation), !Task.isCancelled,
              let session = connections.values.first(where: { $0.channel === transport }), authorized(session) else {
            throw CancellationError()
        }
        let configuration = HostMediaPipeline.Configuration(displayID: displayID, width: width, height: height,
            desktop: desktop, quality: streamQuality, acknowledgesFrames: acknowledgesFrames)
        let next = HostMediaPipeline(configuration: configuration, transport: transport, audio: audio)
        mediaConfiguration = configuration; pipeline = next
        next.onFailure = { [weak self, weak transport] failure in
            guard let self, let transport, self.pipelineIsCurrent(transport, generation: generation) else { return }
            self.captureFailed(failure, transport: transport, generation: generation)
        }
        #if DEBUG
        if interruptNextCaptureStart {
            interruptNextCaptureStart = false
            throw DebugCaptureFaults.interruption
        }
        #endif
        try await next.start()
        guard pipelineIsCurrent(transport, generation: generation) else { await next.stop(); throw CancellationError() }
    }

    private func invalidatePipeline() {
        pipeline?.retire()
        pipelineGeneration &+= 1
    }

    private func retirePipeline() async {
        pipeline?.retire()
        let previous = pipeline, previousCleanup = cleanup
        pipeline = nil
        let retirement = Task {
            await previousCleanup?.value
            await previous?.stop()
        }
        cleanup = retirement
        await retirement.value
    }

    private func startResizeWorker(_ session: HostConnection) {
        guard !starting, captureRecoveryTask == nil, resizeTask == nil, pendingResize != nil else { return }
        resizeTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await self.resizeLoop(session)
        }
    }

    private func resizeLoop(_ session: HostConnection) async {
        defer { if channel === session.channel { resizeTask = nil; activeResize = nil } }
        while !Task.isCancelled, channel === session.channel, authorized(session), pendingResize != nil {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let request = pendingResize, let display = virtual, let previous = currentDesktop,
                  channel === session.channel, authorized(session) else { return }
            activeResize = request
            pendingResize = nil
            if request.desktop == previous {
                currentDesktopRevision = request.revision; currentDesktopAccepted = true
                session.channel.send(.desktopState, object: DesktopState(revision: request.revision, desktop: previous, ready: true, accepted: true, message: "Connected"))
                activeResize = nil
                continue
            }
            session.reconfiguringUntil = ProcessInfo.processInfo.systemUptime + 8
            canReceiveInput = false; starting = true; input.releaseAll()
            nativeTouch.suspend()
            await nativeTouch.waitForRelease()
            guard !Task.isCancelled, channel === session.channel, authorized(session) else { return }
            invalidatePipeline()
            var generation = pipelineGeneration
            trace("resize begin revision=\(request.revision) display=\(display.displayID) generation=\(generation)")
            session.channel.send(.desktopState, object: DesktopState(revision: request.revision, desktop: previous, ready: false, accepted: true, message: "Resizing desktop…"))
            await retirePipeline()
            guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
            do {
                var accepted = true
                var effective: DesktopSize
                do { effective = try await applyDesktop(request.desktop, to: display) }
                catch {
                    try Task.checkCancellation()
                    session.reconfiguringUntil = ProcessInfo.processInfo.systemUptime + 8
                    try await display.resize(width: previous.width, height: previous.height, scale: previous.scale)
                    effective = previous; accepted = false
                }
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session) else { return }
                #if DEBUG
                if interruptNextResize {
                    interruptNextResize = false
                    captureFailed(DebugCaptureFaults.interruption,
                        transport: session.channel, generation: generation)
                    return
                }
                #endif
                currentDesktop = effective
                currentDesktopRevision = request.revision; currentDesktopAccepted = accepted
                let dimensions = StreamDimensions.forDesktop(effective, quality: streamQuality)
                do {
                    try await startPipeline(displayID: display.displayID, width: dimensions.width, height: dimensions.height,
                                            desktop: effective, transport: session.channel, generation: generation)
                } catch {
                    try Task.checkCancellation()
                    guard pipelineIsCurrent(session.channel, generation: generation), authorized(session) else { return }
                    let failure = CaptureFailure(error)
                    if failure.canRestartCapture || failure.requiresUserAction {
                        captureFailed(failure, transport: session.channel, generation: generation)
                        return
                    }
                    session.reconfiguringUntil = ProcessInfo.processInfo.systemUptime + 8
                    invalidatePipeline(); generation = pipelineGeneration
                    await retirePipeline()
                    guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
                    try await display.resize(width: previous.width, height: previous.height, scale: previous.scale)
                    guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
                    effective = previous; currentDesktop = previous; accepted = false
                    currentDesktopRevision = request.revision; currentDesktopAccepted = false
                    let restored = StreamDimensions.forDesktop(previous, quality: streamQuality)
                    try await startPipeline(displayID: display.displayID, width: restored.width, height: restored.height,
                                            desktop: previous, transport: session.channel, generation: generation)
                }
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session) else { return }
                session.reconfiguringUntil = ProcessInfo.processInfo.systemUptime + 8
                try await replayInput(session, generation: generation)
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session) else { return }
                session.reconfiguringUntil = nil; starting = false; canReceiveInput = true
                await nativeTouch.resume(displayID: display.displayID)
                guard pipelineIsCurrent(session.channel, generation: generation) else { return }
                session.channel.send(.desktopState, object: DesktopState(revision: request.revision, desktop: effective, ready: true, accepted: accepted,
                    message: accepted ? "Connected" : "The Mac kept the previous desktop size."))
                trace("resize ready revision=\(request.revision) display=\(display.displayID) generation=\(generation)")
                activeResize = nil
            } catch {
                guard pipelineIsCurrent(session.channel, generation: generation) else { return }
                let failure = CaptureFailure(error)
                if failure.canRestartCapture || failure.requiresUserAction {
                    captureFailed(failure, transport: session.channel, generation: generation)
                    return
                }
                closeConnection(session.id); status = "Desktop resize failed. Reconnect to try again."
                return
            }
        }
    }

    private func captureFailed(_ failure: CaptureFailure, transport: SecureChannel, generation: UInt64) {
        guard pipelineIsCurrent(transport, generation: generation),
              let session = connections.values.first(where: { $0.channel === transport }), authorized(session) else { return }
        trace("capture failed generation=\(generation) domain=\(failure.domain) code=\(failure.code)")
        refreshPermissions()
        if !captureAllowed || failure.requiresUserAction {
            stop(); status = failure.message
            return
        }
        guard supportsCaptureRecovery, failure.canRestartCapture else {
            closeTransport(transport, reason: "capture failed"); status = failure.message
            return
        }
        // A transient error must not mask lost permission or a terminal failure.
        guard failedCaptureGeneration != generation else { return }
        failedCaptureGeneration = generation
        if captureRecoveryTask != nil {
            recoveryFailure = failure
            return
        }

        // Keep the requested size and wait for the old resize worker before recovery.
        if let activeResize, pendingResize.map({ $0.revision < activeResize.revision }) ?? true {
            pendingResize = activeResize
        }
        let previousResize = resizeTask
        previousResize?.cancel()
        invalidatePipeline()
        input.releaseAll(); deferredInput.removeAll()
        nativeTouch.suspend()
        canReceiveInput = false; starting = true
        session.reconfiguringUntil = ProcessInfo.processInfo.systemUptime + 8
        status = "Restoring screen capture…"
        sendCaptureStatus(session, restarting: true)
        captureRecoveryTask = Task { [weak self, weak session] in
            await previousResize?.value
            guard let self, let session, self.channel === session.channel, self.authorized(session), !Task.isCancelled else { return }
            await self.restoreCapture(session)
        }
    }

    private func restoreCapture(_ session: HostConnection) async {
        defer { if channel === session.channel { captureRecoveryTask = nil } }
        while channel === session.channel, authorized(session), !Task.isCancelled {
            guard captureRecoveryBudget.beginAttempt(now: ProcessInfo.processInfo.systemUptime) else {
                stop(); status = "Screen capture couldn't be restored. Start sharing to try again."
                trace("capture recovery limit reached")
                return
            }
            invalidatePipeline()
            let generation = pipelineGeneration
            recoveryFailure = nil
            session.reconfiguringUntil = ProcessInfo.processInfo.systemUptime + 8
            trace("capture restart display=\(activeDisplayID) generation=\(generation)")
            await retirePipeline()
            guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                refreshPermissions()
                guard captureAllowed else {
                    stop(); status = "Allow screen recording on the Mac, then start sharing."
                    return
                }
                // Restore the committed size before applying queued resizes.
                if let virtual, let currentDesktop {
                    try await virtual.resize(width: currentDesktop.width, height: currentDesktop.height, scale: currentDesktop.scale)
                }
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
                let dimensions = currentDesktop.map { StreamDimensions.forDesktop($0, quality: streamQuality) }
                try await startPipeline(displayID: activeDisplayID, width: dimensions?.width ?? mediaConfiguration?.width ?? 0,
                                        height: dimensions?.height ?? mediaConfiguration?.height ?? 0, desktop: currentDesktop,
                                        transport: session.channel, generation: generation)
                guard let currentPipeline = pipeline else { throw CancellationError() }
                do {
                    try await currentPipeline.waitForFirstFrame(until: session.reconfiguringUntil ?? 0)
                } catch HostMediaPipeline.StartupError.timedOut {
                    stop(); status = "Screen capture didn't resume. Start sharing to try again."
                    return
                }
                if let recoveryFailure { throw recoveryFailure }
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
                input.releaseAll()
                session.reconfiguringUntil = nil; starting = false; canReceiveInput = true
                await nativeTouch.resume(displayID: activeDisplayID)
                guard pipelineIsCurrent(session.channel, generation: generation) else { return }
                recoveryFailure = nil; captureRecoveryTask = nil
                status = streamMode == .extend ? "Sharing temporary display" : "Sharing existing display"
                wake.acquire()
                if let currentDesktop {
                    session.channel.send(.desktopState, object: DesktopState(revision: currentDesktopRevision,
                        desktop: currentDesktop, ready: true, accepted: currentDesktopAccepted, message: "Connected"))
                }
                sendCaptureStatus(session, restarting: false)
                trace("capture restored session=\(session.id) display=\(activeDisplayID) generation=\(generation)")
                startResizeWorker(session)
                return
            } catch {
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session), !Task.isCancelled else { return }
                let failure = error as? CaptureFailure ?? CaptureFailure(error)
                trace("capture restart failed domain=\(failure.domain) code=\(failure.code)")
                guard failure.canRestartCapture else { stop(); status = failure.message; return }
            }
        }
    }

    private func sendCaptureStatus(_ session: HostConnection, restarting: Bool) {
        session.channel.send(.status, object: HostStatus(capabilities: Capabilities(canCapture: captureAllowed,
            canControl: inputAllowed && activeAllowsControl, canCreateDisplay: VirtualDisplayHandle.isAvailable, canPlayAudio: captureAllowed),
            message: restarting ? "Restoring screen capture…" : "Connected", captureRestarting: restarting))
    }

    private func trace(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--connection-diagnostics") else { return }
        let line = "DuoHost t=\(ProcessInfo.processInfo.systemUptime) \(event)\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        #endif
    }

    private func replayInput(_ session: HostConnection, generation: UInt64) async throws {
        replayingInput = true
        defer { if channel === session.channel { replayingInput = false } }
        while true {
            let events = deferredInput.take()
            if events.isEmpty { return }
            for event in events {
                // Deliver queued text before releasing keys or changing its target.
                if [.releaseAll, .leftDown, .rightClick].contains(event.kind) {
                    try await input.waitForKeyboardDelivery()
                }
                try Task.checkCancellation()
                guard pipelineIsCurrent(session.channel, generation: generation), authorized(session),
                      activeAllowsControl, inputAllowed else { throw CancellationError() }
                receivedInputCount += 1; lastInputKind = event.kind.rawValue; input.apply(event)
            }
            try await input.waitForKeyboardDelivery()
        }
    }
}
