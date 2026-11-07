import SwiftUI
import DuoCore

struct HostEditorView: View {
    let model: SessionModel
    let host: HostProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var port: String
    @State private var mode: WorkspaceMode
    @State private var invitation = ""
    @State private var customAddress = false
    @State private var pairingPort = ""
    @State private var errorMessage: String?

    init(model: SessionModel, host: HostProfile? = nil) {
        self.model = model; self.host = host
        _name = State(initialValue: host?.name ?? "")
        _address = State(initialValue: host?.address ?? "")
        _port = State(initialValue: String(host?.port ?? 47991))
        _mode = State(initialValue: host?.mode ?? .extend)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(host == nil ? "Pairing invitation" : "New pairing invitation", text: $invitation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in invitation = values.first ?? "" }
                        .labelStyle(.titleAndIcon)
                } header: { Text("Pairing") }
                footer: { Text("Paste an invitation from Duo Workspace Host on your Mac. Then compare the codes and approve there. Invitations expire after five minutes.") }
                Section("Mac") {
                    TextField(host == nil ? "Mac name (optional)" : "Mac name", text: $name).textContentType(.nickname)
                    if host == nil || !invitation.isEmpty {
                        Toggle("Use a different address", isOn: $customAddress)
                            .accessibilityIdentifier("pairing.customAddress")
                    }
                    if (host != nil && invitation.isEmpty) || customAddress {
                        TextField("Hostname or IP address", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("pairing.address")
                        Text("Use an address your device can reach, including a VPN address.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    AdaptiveFormPicker("Default workspace", selection: $mode) {
                        Text("Control Mac").fixedSize(horizontal: false, vertical: true).tag(WorkspaceMode.control)
                        Text("Use as Display").fixedSize(horizontal: false, vertical: true).tag(WorkspaceMode.extend)
                    }
                }
                if (host != nil && invitation.isEmpty) || customAddress {
                    DisclosureGroup("Advanced") {
                        if host == nil || !invitation.isEmpty {
                            TextField("Port", text: $pairingPort, prompt: Text("Use invitation port"))
                                .keyboardType(.numberPad)
                        } else { TextField("Port", text: $port).keyboardType(.numberPad) }
                    }
                }
            }
            .alert("Check the Mac details", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .navigationTitle(host == nil ? "Pair Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(invitation.isEmpty && host != nil ? "Save" : "Pair", action: save)
                        .fontWeight(.semibold).disabled(host == nil && invitation.isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            if !invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var parsed = try PairingInvitation.parse(invitation)
                if customAddress {
                    let enteredPort = pairingPort.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedPort = enteredPort.isEmpty ? parsed.port : UInt16(enteredPort)
                    guard let resolvedPort, resolvedPort > 0, HostAddress.normalized(address) != nil else { throw HostFormError.address }
                    parsed = try parsed.overridingAddress(address, port: resolvedPort)
                }
                try model.preparePairing(parsed, name: name.isEmpty ? nil : name, mode: mode, replacing: host?.id)
            } else {
                guard let host, let port = UInt16(port), port > 0 else { throw HostFormError.address }
                try model.library.update(id: host.id, name: name, address: address, port: port, mode: mode)
            }
            invitation = ""
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
