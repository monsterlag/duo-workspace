import AppKit

enum DockVisibility {
    static let key = "showInDock"

    static var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func apply(_ shown: Bool) {
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
        NSApp.activate()
    }
}
