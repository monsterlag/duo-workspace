import Foundation
import Network
import Security

public final class SecureChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "DuoWorkspace.Channel")
    private var decoder: PacketDecoder
    private var sequence: UInt64 = 0
    private var closed = false
    private var finishing = false
    private var delivering = false
    private var deferredFailure: (String, Bool)?
    private var receiveBudget = TrafficBudget()
    // Set handlers before start(). Async handlers preserve wire order and
    // backpressure; synchronous handlers are retained for lightweight probes.
    public var onReady: (() -> Void)?
    public var onPacket: ((Packet) -> Void)?
    public var onReadyAsync: (@Sendable () async -> Void)?
    public var onPacketAsync: (@Sendable (Packet) async -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onAuthenticationFailure: (() -> Void)?

    public init(_ connection: NWConnection, maximumIncomingPayload: Int = PacketDecoder.maximumPayload) {
        self.connection = connection
        decoder = PacketDecoder(maximumPayload: maximumIncomingPayload)
    }

    public var peerPublicKeyPin: Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13 else { return nil }
        var pin: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if pin == nil {
                let cert = sec_certificate_copy_ref(certificate).takeRetainedValue()
                pin = LocalIdentity.pin(certificate: SecCertificateCopyData(cert) as Data)
            }
        }
        return pin
    }

    public var isTLS13: Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13
    }

    public func pairingVerificationCode(hostPin: Data, devicePin: Data) -> String? {
        guard hostPin.count == 32, devicePin.count == 32, let secret = pairingSessionBinding() else { return nil }
        return PairingInvitation.verificationCode(hostPin: hostPin, devicePin: devicePin, sessionSecret: secret)
    }

    func pairingSessionBinding() -> Data? {
        guard isTLS13, let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = "EXPORTER-DuoWorkspace-Pairing-v2"
        let secret = label.withCString {
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32)
        }
        guard let secret else { return nil }
        return Data(secret as DispatchData)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed, !self.finishing else { return }
            switch state {
            case .ready:
                if let handler = self.onReadyAsync {
                    self.delivering = true
                    Task { [self] in
                        await handler()
                        self.queue.async { [self] in self.deliveryCompleted(done: false, error: nil) }
                    }
                } else { self.onReady?(); self.receive() }
            case .failed(let error), .waiting(let error):
                self.fail(error.localizedDescription, authentication: Self.isAuthenticationFailure(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ kind: MessageKind, payload: Data, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, !self.closed, !self.finishing else { completion?(); return }
            self.sequence &+= 1
            do {
                let data = try Packet(kind: kind, sequence: self.sequence, payload: payload).encoded()
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error { self?.fail(error.localizedDescription, authentication: Self.isAuthenticationFailure(error)) }
                    completion?()
                })
            } catch { self.fail("Invalid outgoing packet"); completion?() }
        }
    }

    public func send<T: Encodable>(_ kind: MessageKind, object: T) {
        do { send(kind, payload: try JSONEncoder().encode(object)) }
        catch {
            queue.async { [weak self] in self?.fail("Invalid outgoing message") }
        }
    }

    public func cancel() {
        queue.async { [self] in closed = true; connection.cancel() }
    }

    /// The queue is a barrier: already queued releases are drained, later sends
    /// are rejected, and no further reads start after a planned disconnect.
    public func finish() {
        queue.async { [self] in
            guard !closed, !finishing else { return }
            finishing = true
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [self] _ in cancel() })
            queue.asyncAfter(deadline: .now() + 2) { [self] in closed = true; connection.cancel() }
        }
    }

    private static func isAuthenticationFailure(_ error: NWError) -> Bool {
        guard case .tls(let status) = error else { return false }
        // Network.framework also reports connection loss in the TLS domain,
        // including when a peer closes before sending any certificate.
        switch status {
        case errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify,
             errSSLConnectionRefused, errSSLNetworkTimeout:
            return false
        default:
            return true
        }
    }

    private func fail(_ message: String, authentication: Bool = false) {
        guard !closed, !finishing else { return }
        if delivering {
            if deferredFailure == nil { deferredFailure = (message, authentication) }
            connection.cancel()
            return
        }
        closed = true
        if authentication, let onAuthenticationFailure { onAuthenticationFailure() }
        else { onFailure?(message) }
        connection.cancel()
    }

    private func deliveryCompleted(done: Bool, error: NWError?) {
        delivering = false
        guard !closed, !finishing else { return }
        if let failure = deferredFailure {
            deferredFailure = nil
            fail(failure.0, authentication: failure.1)
        } else if let error { fail(error.localizedDescription, authentication: Self.isAuthenticationFailure(error)) }
        else if done { fail("Connection closed") }
        else { receive() }
    }

    private func receive() {
        guard !closed, !finishing else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed, !self.finishing else { return }
            do {
                let arrival = ProcessInfo.processInfo.systemUptime
                let packets = try (data.map { try self.decoder.append($0) } ?? []).map { packet in
                    var packet = packet; packet.receivedAt = arrival; return packet
                }
                for _ in packets {
                    guard self.receiveBudget.consume(now: ProcessInfo.processInfo.systemUptime) else {
                        self.fail("Incoming packet rate exceeded"); return
                    }
                }
                if let handler = self.onPacketAsync, !packets.isEmpty {
                    self.delivering = true
                    Task { [self] in
                        for packet in packets { await handler(packet) }
                        self.queue.async { [self] in self.deliveryCompleted(done: done, error: error) }
                    }
                } else {
                    for packet in packets { self.onPacket?(packet) }
                    self.deliveryCompleted(done: done, error: error)
                }
            } catch { self.fail("Protocol validation failed") }
        }
    }
}
