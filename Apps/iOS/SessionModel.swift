import Foundation
import Observation
import Network
import UIKit
import DuoCore

@MainActor @Observable
final class SessionModel {
    private(set) var state: SessionState = .disconnected
    private(set) var active: HostProfile?
    private(set) var message = ""
    private(set) var canControl = false
    private(set) var supportsClipboard = false
    private(set) var supportsAudio = false
    private(set) var supportsFileTransfer = false
    var canSendInput: Bool { canControl && hasVideo && state == .connected }
    private(set) var hasVideo = false
    private(set) var frameAspect = 1.6
    private(set) var roundTripMilliseconds: Double?
    private(set) var receivedFrames = 0
    private(set) var streamWidth = 0
    private(set) var streamHeight = 0
    private(set) var reconnectAttempt = 0
    var libraryError: String?
    var presentsSession = false
    private(set) var verificationCode: String?
    private(set) var awaitingApproval = false
    private(set) var needsPairing = false
    @ObservationIgnored private var pairing: PairingPlan?
    @ObservationIgnored private var sessionAuthorized = false
    @ObservationIgnored private var preparedPair: PairingPlan?

    func preparePairing(_ invitation: PairingInvitation, name: String?, mode: WorkspaceMode, replacing id: UUID?) throws {
        preparedPair = try PairingPlan(invitation, name: name, mode: mode, replacing: id)
    }

    func startPreparedPairing() {
        guard let plan = preparedPair else { return }
        preparedPair = nil
        do { try startPairing(plan) }
        catch { libraryError = error.localizedDescription }
    }

    let settings: AppSettings
    let library: HostLibrary
    let display: SessionDisplay
    let input: SessionInputController
    let nativeTouch = SessionNativeTouch()
    var workspacePointerMode: PointerMode {
        if settings.pointerMode == .nativeTouch,
           !nativeTouch.supported || nativeTouch.status.state == .unavailable { return .direct }
        return settings.pointerMode
    }
    let clipboard = SessionClipboard()
    let audio: SessionAudio
    let microphone: SessionMicrophone
    let files = SessionFiles()
    @ObservationIgnored let renderer = VideoRenderer()
    @ObservationIgnored private let factory = VideoSampleFactory()
    @ObservationIgnored private let credentials: any ClientCredentials
    @ObservationIgnored private var channel: SecureChannel?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var health: ConnectionHealth?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var restoringCapture = false
    @ObservationIgnored private var recoveryFrameReceived = false
    @ObservationIgnored private var supportsFrameAcks = false
    @ObservationIgnored private var pendingAck: (id: UInt32, enqueuedAt: TimeInterval)?
    @ObservationIgnored private var lastAckSent = -Double.infinity
    @ObservationIgnored private var ackTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, credentials: any ClientCredentials = KeychainClientCredentials()) {
        self.credentials = credentials
        settings = AppSettings(defaults: defaults)
        library = HostLibrary(defaults: defaults, credentials: credentials)
        display = SessionDisplay(settings: settings)
        input = SessionInputController(settings: settings)
        let audioSession = ClientAudioSession()
        audio = SessionAudio(audioSession: audioSession)
        microphone = SessionMicrophone(audioSession: audioSession)
        input.emit = { [weak self] event in self?.send(event) }
        input.acceptsInput = { [weak self] in self?.canSendInput == true }
        nativeTouch.gestureEnded = { [weak input = self.input] in input?.finishNativeTouch() }
        nativeTouch.positionChanged = { [weak input = self.input] in input?.rememberNativeTouch($0) }
        nativeTouch.sendControl = { [weak self] request in
            guard let self, self.sessionAuthorized, self.nativeTouch.supported, self.canControl,
                  let channel = self.channel else { return false }
            channel.send(.nativeTouchControl, object: request)
            return true
        }
        nativeTouch.sendFrame = { [weak self] frame in
            guard let self, self.sessionAuthorized, self.canSendInput, !self.display.resizing,
                  frame.isValid else { return }
            self.channel?.send(.nativeTouchFrame, object: frame)
        }
        display.sendHello = { [weak self] hello in
            guard let self, self.sessionAuthorized else { return }
            var hello = hello
            if self.supportsFrameAcks { hello.supportsFrameAcks = true }
            self.channel?.send(.hello, object: hello)
        }
        display.sendResize = { [weak self] request in
            guard let self, self.sessionAuthorized else { return }
            self.channel?.send(.resizeDesktop, object: request)
        }
        display.willResize = { [weak input = self.input] in input?.releaseHeldInput() }
    }

    func pair(_ invitation: PairingInvitation, name: String? = nil, mode: WorkspaceMode = .control, replacing id: UUID? = nil) throws {
        try startPairing(PairingPlan(invitation, name: name, mode: mode, replacing: id))
    }

    private func startPairing(_ plan: PairingPlan) throws {
        guard plan.invitation.expiresAt > Date() else { throw IdentityError.expiredInvitation }
        disconnect()
        pairing = plan
        active = plan.host
        display.begin(mode: plan.host.mode, quality: settings.quality)
        presentsSession = true; suspended = false; needsPairing = false
        startConnection()
    }

    func connect(_ host: HostProfile, mode: WorkspaceMode? = nil) {
        disconnect()
        active = host
        display.begin(mode: mode ?? host.mode, quality: settings.quality)
        presentsSession = true
        suspended = false
        startConnection()
    }

    private func startConnection() {
        guard let host = active else { return }
        closeTransport()
        state = reconnectAttempt > 0 ? .reconnecting : .connecting
        message = reconnectAttempt > 0 ? "Reconnecting to your Mac…" : "Connecting to your Mac…"
        receivedFrames = 0
        roundTripMilliseconds = nil
        needsPairing = false
        do {
            guard let pin = try pairing?.invitation.hostPin ?? credentials.host(host.id)?.publicKeyPin else {
                needsPairing = true
                throw HostFormError.pairingMissing
            }
            let identity = try credentials.identity()
            guard let port = NWEndpoint.Port(rawValue: host.port) else { throw HostFormError.address }
            let connection = NWConnection(host: NWEndpoint.Host(host.address), port: port, using: try SecureParameters.client(identity: identity, hostPin: pin))
            let transport = SecureChannel(connection)
            channel = transport
            health = ConnectionHealth(now: ProcessInfo.processInfo.systemUptime)
            transport.onReadyAsync = { @MainActor [weak self, weak transport] in
                guard let self, let transport, self.channel === transport else { return }
                guard transport.isTLS13, transport.peerPublicKeyPin == pin else {
                    self.fail("Couldn’t verify this Mac’s identity.", retry: false)
                    return
                }
                self.state = .authenticating
                self.message = "Verifying this device…"
                guard let code = transport.pairingVerificationCode(hostPin: pin, devicePin: identity.publicKeyPin) else {
                    self.fail("Couldn’t verify this pairing session.", retry: false); return
                }
                self.verificationCode = code
                transport.send(.authorize, object: AuthorizationRequest(deviceName: UIDevice.current.name, invitationToken: self.pairing?.invitation.token))
            }
            transport.onPacketAsync = { @MainActor [weak self, weak transport] packet in
                guard let self, let transport, self.channel === transport else { return }
                self.receive(packet)
            }
            transport.onFailure = { [weak self, weak transport] _ in
                Task { @MainActor in
                    guard let self, let transport, self.channel === transport else { return }
                    self.fail("Your Mac isn’t responding. Check that it’s awake and sharing.", retry: self.pairing == nil)
                }
            }
            transport.onAuthenticationFailure = { [weak self, weak transport] in
                Task { @MainActor in
                    guard let self, let transport, self.channel === transport else { return }
                    self.needsPairing = true
                    self.fail("Couldn’t verify this connection. Check your Mac, then create a new invitation there.", retry: false)
                }
            }
            transport.start()
            startHealthChecks()
        } catch { fail(errorMessage(error), retry: false) }
    }

    private func receive(_ packet: Packet) {
        do {
            switch packet.kind {
            case .authorization:
                let result = try JSONDecoder().decode(AuthorizationResult.self, from: packet.payload)
                switch result.state {
                case .pending:
                    guard !sessionAuthorized else { throw IdentityError.invalidIdentity }
                    awaitingApproval = true
                    message = result.message
                case .approved:
                    guard !sessionAuthorized, active != nil else { throw IdentityError.invalidIdentity }
                    if let pairing { try library.approve(pairing.host, pin: pairing.invitation.hostPin) }
                    sessionAuthorized = true; awaitingApproval = false; verificationCode = nil
                    health = ConnectionHealth(now: ProcessInfo.processInfo.systemUptime)
                    pairing = nil
                    supportsClipboard = result.supportsClipboard == true
                    supportsAudio = result.supportsAudio == true
                    audio.supportsMacMute = result.supportsMacAudioMute == true
                    supportsFileTransfer = result.supportsFileTransfer == true
                    nativeTouch.supported = result.supportsNativeTouch == true
                    input.supportsFunctionModifier = result.supportsFunctionModifier == true
                    supportsFrameAcks = result.supportsFrameAcks == true
                    microphone.sendControl = { [weak self] request in
                        guard let self, self.sessionAuthorized, let channel = self.channel else { return false }
                        channel.send(.microphoneControl, object: request); return true
                    }
                    microphone.sendFrame = { [weak self] frame, completion in
                        guard let self, self.sessionAuthorized, self.canControl, frame.isValid,
                              let payload = try? JSONEncoder().encode(frame), let channel = self.channel else { return false }
                        channel.send(.microphoneFrame, payload: payload, completion: completion); return true
                    }
                    microphone.connected(supported: result.supportsMicrophone == true)
                    files.makeChannel = { [weak self] in
                        guard let self, self.sessionAuthorized, self.supportsFileTransfer,
                              let host = self.active, let pin = try self.credentials.host(host.id)?.publicKeyPin,
                              let port = NWEndpoint.Port(rawValue: host.port) else { throw IdentityError.invalidIdentity }
                        return SecureChannel(NWConnection(host: NWEndpoint.Host(host.address), port: port,
                            using: try SecureParameters.client(identity: self.credentials.identity(), hostPin: pin)),
                            maximumIncomingPayload: 128 * 1024)
                    }
                    audio.send = { [weak self] request in
                        guard let self, self.supportsAudio, self.sessionAuthorized else { return }
                        self.channel?.send(.audioControl, object: request)
                    }
                    clipboard.send = { [weak self] request in
                        guard let self, self.supportsClipboard, self.canSendInput, let channel = self.channel else { return false }
                        channel.send(.clipboardRequest, object: request)
                        return true
                    }
                    state = .waitingForFrame; message = "Preparing your workspace…"
                    display.connectionApproved(adaptive: result.supportsAdaptiveDisplay == true,
                                               maximumDetail: result.supportsMaximumDetail == true)
                case .denied, .revoked, .busy:
                    needsPairing = result.state != .busy
                    fail(result.message, retry: false)
                }
            case .microphoneStatus:
                guard sessionAuthorized, microphone.supported else { throw IdentityError.invalidIdentity }
                microphone.receive(try JSONDecoder().decode(MicrophoneStatus.self, from: packet.payload))
            case .nativeTouchStatus:
                guard sessionAuthorized, nativeTouch.supported else { throw IdentityError.invalidIdentity }
                let status = try JSONDecoder().decode(NativeTouchStatus.self, from: packet.payload)
                guard status.isValid else { throw IdentityError.invalidIdentity }
                nativeTouch.receive(status)
            case .audioFrame:
                guard sessionAuthorized, supportsAudio else { throw IdentityError.invalidIdentity }
                do { try audio.receive(JSONDecoder().decode(AudioFrame.self, from: packet.payload)) }
                catch { audio.receive(AudioStatus(enabled: false, failed: true)) }
            case .audioStatus:
                guard sessionAuthorized, supportsAudio else { throw IdentityError.invalidIdentity }
                audio.receive(try JSONDecoder().decode(AudioStatus.self, from: packet.payload))
            case .clipboardResponse:
                guard sessionAuthorized, supportsClipboard else { throw IdentityError.invalidIdentity }
                clipboard.receive(try JSONDecoder().decode(ClipboardResponse.self, from: packet.payload))
            case .desktopState:
                guard sessionAuthorized else { throw IdentityError.invalidIdentity }
                let update = try JSONDecoder().decode(DesktopState.self, from: packet.payload)
                try display.receive(update)
                nativeTouch.cancelContacts()
                if hasVideo { message = update.message }
            case .status:
                guard sessionAuthorized else { throw IdentityError.invalidIdentity }
                let status = try JSONDecoder().decode(HostStatus.self, from: packet.payload)
                guard status.capabilities.canCapture else {
                    fail("Allow screen recording for Duo Workspace Host, then reconnect.", retry: false)
                    return
                }
                if canControl && !status.capabilities.canControl {
                    input.releaseAll()
                } else if status.captureRestarting == true {
                    input.releaseHeldInput()
                }
                if status.captureRestarting == true {
                    audio.pause()
                    restoringCapture = true
                    recoveryFrameReceived = false
                    state = .waitingForFrame
                    display.setVideoReady(false)
                }
                canControl = status.capabilities.canControl
                message = status.message
                if status.captureRestarting == false, restoringCapture {
                    input.releaseHeldInput()
                    restoringCapture = false
                    if recoveryFrameReceived {
                        state = .connected
                        message = canControl ? "Connected" : "View only"
                        display.setVideoReady(true)
                    }
                    recoveryFrameReceived = false
                }
                updateNativeTouch()
            case .videoConfiguration:
                guard sessionAuthorized else { throw IdentityError.invalidIdentity }
                let config = try JSONDecoder().decode(VideoConfiguration.self, from: packet.payload)
                try factory.configure(config)
                renderer.clear()
                frameAspect = Double(config.width) / Double(config.height)
                streamWidth = config.width; streamHeight = config.height
            case .videoFrame, .timedVideoFrame, .identifiedVideoFrame:
                guard sessionAuthorized, packet.kind != .identifiedVideoFrame || supportsFrameAcks else {
                    throw IdentityError.invalidIdentity
                }
                var data = packet.payload
                var acknowledgement: UInt32?
                if packet.kind != .videoFrame {
                    let frame = try TimedVideoFrame(encoded: data, identified: packet.kind == .identifiedVideoFrame)
                    audio.noteVideoTime(frame.time); data = frame.data; acknowledgement = frame.id
                }
                renderer.enqueue(try factory.sample(data))
                if let acknowledgement { acknowledge(acknowledgement) }
                receivedFrames += 1
                if restoringCapture {
                    hasVideo = true
                    recoveryFrameReceived = true
                } else if !hasVideo || state == .waitingForFrame {
                    if !hasVideo { audio.sessionReady() }
                    hasVideo = true
                    state = .connected
                    reconnectAttempt = 0
                    message = canControl ? "Connected" : "View only"
                    display.setVideoReady(true)
                    updateNativeTouch()
                }
            case .pong:
                if health?.acknowledge(packet.payload, now: ProcessInfo.processInfo.systemUptime) == true {
                    roundTripMilliseconds = health?.roundTripMilliseconds
                }
            default: break
            }
        } catch let error as IdentityError {
            fail(error.localizedDescription, retry: false)
        } catch { fail("Couldn’t read a message from your Mac. Reconnect to try again.", retry: false) }
    }

    /// The host paces frames and bitrate on acks. They are cumulative, so at most one
    /// is sent per 33 ms carrying the newest enqueued frame and how long it was held.
    private func acknowledge(_ id: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        pendingAck = (id, now)
        guard ackTask == nil else { return }
        let wait = lastAckSent + 0.033 - now
        guard wait > 0 else { flushAck(); return }
        ackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.ackTask = nil; self.flushAck()
        }
    }

    private func flushAck() {
        guard let ack = pendingAck, sessionAuthorized, let channel else { return }
        pendingAck = nil
        let now = ProcessInfo.processInfo.systemUptime
        lastAckSent = now
        let held = Int(((now - ack.enqueuedAt) * 1000).rounded())
        channel.send(.videoFrameAck, payload: TimedVideoFrame.acknowledgement(ack.id, heldMilliseconds: held))
    }

    private func startHealthChecks() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let transport = self.channel, var health = self.health else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if health.isExpired(now: now) {
                    self.fail("Your Mac didn’t respond. Check its connection and try again.", retry: self.pairing == nil)
                    return
                }
                if !self.sessionAuthorized, now - health.startedAt >= (self.awaitingApproval ? 70 : 15) {
                    self.fail("Approval timed out. Create a new invitation on your Mac.", retry: false)
                    return
                }
                if self.sessionAuthorized, !self.hasVideo, now - health.startedAt >= 14 {
                    self.fail("Your Mac connected without video. Check screen recording permission on the Mac.", retry: false)
                    return
                }
                let payload = health.ping(now: now)
                self.health = health
                transport.send(.ping, payload: payload)
            }
        }
    }

    private func fail(_ reason: String, retry: Bool) {
        closeTransport()
        message = reason
        state = .failed(reason)
        guard retry, settings.automaticReconnect, reconnectAttempt < 3, !suspended, active != nil else { return }
        reconnectAttempt += 1
        state = .reconnecting
        let delay = 1 << (reconnectAttempt - 1)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !self.suspended, self.active != nil else { return }
            guard self.settings.automaticReconnect else { self.state = .failed(self.message); return }
            self.startConnection()
        }
    }

    func reconnect() {
        guard active != nil else { return }
        retryTask?.cancel()
        reconnectAttempt = 0
        suspended = false
        display.begin(mode: display.mode, quality: settings.quality)
        startConnection()
    }

    func setSceneActive(_ isActive: Bool) {
        guard active != nil else { return }
        if isActive {
            if suspended { reconnect() }
        } else {
            suspended = true
            closeTransport()
            state = .disconnected
            message = "Session paused while you’re away from Duo Workspace."
        }
    }

    func send(_ event: InputEvent) {
        guard event.isValid else { return }
        if event.kind != .releaseAll { guard canSendInput else { return } }
        channel?.send(.input, object: event)
        if event.kind == .releaseAll { nativeTouch.cancelContacts() }
    }

    func updateNativeTouch() {
        nativeTouch.setEnabled(settings.pointerMode == .nativeTouch && canSendInput)
    }

    func retryNativeTouch() {
        nativeTouch.setEnabled(false)
        updateNativeTouch()
    }

    func releaseInput() { input.releaseAll() }

    func disconnect() {
        closeTransport()
        active = nil
        display.disconnect()
        pairing = nil
        verificationCode = nil; needsPairing = false
        presentsSession = false
        reconnectAttempt = 0
        state = .disconnected
        message = ""
    }

    private func closeTransport() {
        display.resetTransport()
        restoringCapture = false; recoveryFrameReceived = false
        streamWidth = 0; streamHeight = 0
        retryTask?.cancel()
        healthTask?.cancel()
        input.releaseAll()
        nativeTouch.disconnect()
        input.supportsFunctionModifier = false
        supportsFrameAcks = false
        ackTask?.cancel(); ackTask = nil; pendingAck = nil; lastAckSent = -.infinity
        channel?.finish()
        channel = nil
        health = nil
        hasVideo = false
        canControl = false
        sessionAuthorized = false; awaitingApproval = false
        supportsClipboard = false; clipboard.disconnect()
        supportsAudio = false; audio.disconnect()
        microphone.disconnect()
        supportsFileTransfer = false; files.disconnect()
        renderer.clear()
        factory.reset()
    }

    private func errorMessage(_ error: Error) -> String {
        if let formError = error as? HostFormError { return formError.localizedDescription }
        return (error as? IdentityError)?.localizedDescription ?? "Can’t read the saved device identity. Check Keychain access."
    }
}
