import CoreGraphics
import Foundation
import DuoCore

@MainActor
protocol NativeTouchDevice: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func start(displayID: CGDirectDisplayID) async throws
    func enqueue(_ contacts: [NativeTouchContact])
    func releaseAll()
    func waitForLift() async
    func stop() async
}

/// Accepts contacts only for the active, authorized display context.
@MainActor
final class NativeTouchController {
    static var isSupported: Bool {
        if #available(macOS 27.3, *) { return true }
        return false
    }

    var onStatus: ((NativeTouchStatus) -> Void)?
    private(set) var status = NativeTouchStatus(.off)
    private(set) var requested = false
    private var device: (any NativeTouchDevice)?
    private var retirement: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var needsNeutral = true
    private var lastFrameTime: TimeInterval = 0
    private(set) var hasContacts = false
    private var displayID: CGDirectDisplayID = 0
    private var displayBounds = CGRect.zero
    private let supported: Bool
    private let allowed: () -> Bool
    private let makeDevice: () -> (any NativeTouchDevice)?
    private let now: () -> TimeInterval

    init(supported: Bool? = nil, allowed: @escaping () -> Bool,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeDevice: (() -> (any NativeTouchDevice)?)? = nil) {
        self.supported = supported ?? Self.isSupported
        self.allowed = allowed; self.now = now
        self.makeDevice = makeDevice ?? {
            if #available(macOS 27.3, *) { return SystemNativeTouchDevice() }
            return nil
        }
    }

    func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID, ready: Bool = true) async {
        requested = enabled
        if enabled && ready { await resume(displayID: displayID) }
        else if enabled { suspend() }
        else { retire(with: NativeTouchStatus(.off)) }
    }

    func resume(displayID: CGDirectDisplayID) async {
        guard requested else { return }
        retire(with: NativeTouchStatus(.starting))
        let token = generation
        await retirement?.value
        guard requested, token == generation else { return }
        guard supported else { publish(NativeTouchStatus(.unavailable, failure: .macOSVersion)); return }
        guard allowed() else { publish(NativeTouchStatus(.unavailable, failure: .permission)); return }
        guard let next = makeDevice() else {
            publish(NativeTouchStatus(.unavailable, failure: .macOSVersion))
            return
        }
        next.onFailure = { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.retire(with: NativeTouchStatus(.unavailable, failure: .device))
        }
        do {
            try await next.start(displayID: displayID)
            guard token == generation, requested else { await next.stop(); return }
            guard allowed() else {
                await next.stop()
                guard token == generation, requested else { return }
                publish(NativeTouchStatus(.unavailable, failure: .permission))
                return
            }
            self.displayID = displayID; displayBounds = CGDisplayBounds(displayID)
            device = next; needsNeutral = true; hasContacts = false; lastFrameTime = now()
            publish(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.generation == token else { return }
                    self.checkLiveness()
                }
            }
        } catch {
            await next.stop()
            guard token == generation else { return }
            publish(NativeTouchStatus(.unavailable, failure: .device))
        }
    }

    @discardableResult
    func receive(_ frame: NativeTouchFrame) -> Bool {
        guard frame.isValid, status.state == .ready, frame.contextID == status.contextID else { return false }
        guard allowed() else { retire(with: NativeTouchStatus(.unavailable, failure: .permission)); return false }
        guard CGDisplayBounds(displayID) == displayBounds else {
            retire(with: NativeTouchStatus(.unavailable, failure: .display)); return false
        }
        lastFrameTime = now()
        if frame.contacts.isEmpty { needsNeutral = false }
        guard !needsNeutral else { return false }
        hasContacts = !frame.contacts.isEmpty
        device?.enqueue(frame.contacts)
        return true
    }

    func releaseContacts() {
        device?.releaseAll(); needsNeutral = true; hasContacts = false
    }

    func waitForLift() async {
        guard !hasContacts else { return }
        await device?.waitForLift()
    }

    func checkLiveness() {
        guard status.state == .ready else { return }
        guard allowed() else { retire(with: NativeTouchStatus(.unavailable, failure: .permission)); return }
        if hasContacts && now() - lastFrameTime > 0.7 {
            releaseContacts()
            // A stalled sender must see the new context before it can resume.
            publish(NativeTouchStatus(.ready, contextID: UUID(), supportsEdgeGestures: true))
        }
    }

    func suspend() { retire(with: NativeTouchStatus(.paused)) }
    func waitForRelease() async { await retirement?.value }
    func stop() { requested = false; retire(with: NativeTouchStatus(.off)) }

    private func retire(with state: NativeTouchStatus) {
        generation = UUID(); watchdog?.cancel(); watchdog = nil
        releaseContacts()
        let previous = device, previousRetirement = retirement
        device = nil
        retirement = Task {
            await previousRetirement?.value
            await previous?.stop()
        }
        publish(state)
    }

    private func publish(_ value: NativeTouchStatus) {
        status = value; onStatus?(value)
    }
}
