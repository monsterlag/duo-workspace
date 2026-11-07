import SwiftUI
import DuoHost

struct PairingSection: View {
    let host: HostController
    @State private var copied = false
    @State private var address = ""

    var body: some View {
        Section("Pair a device") {
            Text("Create an invitation, then approve the device here to let it view and control your Mac.")
            if !host.access.isReady {
                Text(host.access.message).foregroundStyle(.secondary)
                Button("Retry Keychain access") { host.access.load() }.disabled(host.access.loading)
            } else if let invitation = host.access.invitation {
                LabeledContent("Invitation expires") { Text(invitation.expiresAt, style: .time) }
                Button(copied ? "Invitation copied" : "Copy invitation", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    guard let link = try? invitation.link() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                }
                Button("Cancel invitation", role: .cancel) { host.access.cancelInvitation(); copied = false }
            } else {
                TextField("Connection address (optional)", text: $address)
                    .help("Leave blank to use this Mac's Tailscale address, or its hostname without Tailscale.")
                Button("Create invitation", systemImage: "plus.circle") {
                    copied = false
                    let entered = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    host.access.makeInvitation(name: Host.current().localizedName ?? "My Mac",
                                               address: entered.isEmpty ? (Self.tailscaleAddress() ?? ProcessInfo.processInfo.hostName) : entered)
                }.disabled(!host.sharing)
                if !host.sharing { Text("Start sharing to pair a device.").font(.caption).foregroundStyle(.secondary) }
            }
            if host.access.isReady && !host.access.message.isEmpty { Text(host.access.message).font(.caption).foregroundStyle(.secondary) }
            if host.access.storageWarning != nil {
                if host.access.storageWarning != host.access.message {
                    Text(host.access.storageWarning ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Button("Retry saving") { host.access.retryStorage() }
            }
        }
    }

    /// This Mac's Tailscale IPv4 address (100.64.0.0/10), so a pairing works away from home.
    static func tailscaleAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard ip >> 22 == (100 << 2) | 1 else { continue }
            return "\(ip >> 24).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
        }
        return nil
    }
}
