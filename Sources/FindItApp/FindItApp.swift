import SwiftUI
import AppKit

/// App Delegate — 确保 SPM 可执行目标能显示为前台 GUI 应用
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct FindItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var authManager = AuthManager()
    @State private var subscriptionManager = SubscriptionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { FolderCommands() }
        .environment(authManager)
        .environment(subscriptionManager)

        Settings {
            SettingsView()
        }
        .environment(authManager)
        .environment(subscriptionManager)
    }

    // NOTE: findit:// URL scheme not available in SPM builds (no Info.plist).
    // Stripe redirects go to checkout-result Edge Function landing page instead.
    // Subscription refresh happens via didBecomeActive in ContentView.
}
