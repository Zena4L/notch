import SwiftUI

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: Bindable(appDelegate.settings).showMenuBarIcon) {
            MenuContent()
        } label: {
            MenuBarLabel(
                settings: appDelegate.settings, nowPlaying: appDelegate.nowPlaying,
                timers: appDelegate.timers, downloads: appDelegate.downloads
            )
        }

        Settings {
            SettingsView()
                .environment(appDelegate.settings)
                .environment(appDelegate.calendar)
                .environment(appDelegate.hotkeyStatus)
                .environment(appDelegate.hud)
                .environment(appDelegate.downloads)
        }
    }
}

private struct MenuContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Notch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
