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
            HistoryGridView()
                .environment(\.managedObjectContext, store.container.viewContext)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(panel: panel, store: store, sync: sync)
        }
    }
}
