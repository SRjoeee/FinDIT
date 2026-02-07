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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { FolderCommands() }
    }
}
