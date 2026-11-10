import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(DockVisibility.key) private var showInDock = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, shown in DockVisibility.apply(shown) }
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in setOpensAtLogin(enabled) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Duo Workspace Host stays in the menu bar when it isn't in the Dock. Closing its window doesn't stop sharing.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
