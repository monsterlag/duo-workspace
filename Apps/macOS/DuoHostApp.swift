import SwiftUI
import DuoHost

final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !DockVisibility.isShown { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct DuoHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate
    @State private var host = HostController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Duo Workspace Host", id: "host") {
            HostView(host: host).frame(minWidth: 460, minHeight: 560)
        }
        .defaultSize(width: 520, height: 680)
        Settings { SettingsView() }
        MenuBarExtra {
            Text(host.status)
            if let request = host.access.pending.first {
                Button("Approve “\(request.name)”…", action: showHost)
            }
            Button(host.sharing ? "Stop Sharing" : "Start Sharing") {
                host.sharing ? host.stop() : host.start()
            }.disabled(!host.access.isReady)
            Divider()
            Button("Open Duo Workspace Host", action: showHost)
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Duo Workspace") { host.stop(); NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "display.2").symbolVariant(host.sharing ? .fill : .none)
                .onChange(of: host.access.pending.count) { old, new in if new > old { showHost() } }
        }
    }

    private func showHost() {
        openWindow(id: "host")
        NSApp.activate()
    }
}
