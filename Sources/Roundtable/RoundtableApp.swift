import SwiftUI

struct RoundtableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is menu-bar driven from the AppDelegate (AppKit NSStatusItem),
        // so we need no real scene. Settings is an inert placeholder.
        Settings { EmptyView() }
    }
}

/// Menu-bar-only agent app: no dock icon, no main window. Boots the AppKit
/// status-item controller and the polling engine.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(store: SessionStore.shared)
        SessionStore.shared.start()
    }
}
