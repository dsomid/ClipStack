import SwiftUI
import CoreData

@main
struct ClipStackApp: App {
    let store: ClipStore
    let monitor: PasteboardMonitor
    let panel: PanelController
    let sync: SyncStatus

    init() {
        Prefs.registerDefaults()
        store = ClipStore()
        sync = SyncStatus(container: store.container, enabled: store.isSyncEnabled)
        if store.isSyncEnabled {
            // Silent pushes tell Core Data that another device changed the CloudKit zone.
            NSApplication.shared.registerForRemoteNotifications()
        }
        monitor = PasteboardMonitor(store: store)
        monitor.start()
        panel = PanelController(store: store)
        if !panel.register() {
            NSLog("ClipStack: shortcut is already in use by another app")
        }
    }

    var body: some Scene {
        MenuBarExtra("ClipStack", systemImage: "doc.on.clipboard") {
            MenuContent(panel: panel)
        }

        Settings {
            SettingsView(panel: panel, store: store, sync: sync)
        }
    }
}

private struct MenuContent: View {
    let panel: PanelController
    @AppStorage(Prefs.capturePaused) private var paused = false

    var body: some View {
        Button("Open ClipStack  \(Shortcut.saved.displayString)") {
            // Let the menu finish closing first, or it steals key status from the shelf.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { panel.show() }
        }
        Toggle("Pause Capture", isOn: $paused)
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
        Button("Quit ClipStack") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
