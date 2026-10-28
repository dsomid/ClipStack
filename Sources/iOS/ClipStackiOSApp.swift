import SwiftUI
import CoreData

@main
struct ClipStackiOSApp: App {
    let store: ClipStore
    @StateObject private var clipboard = ClipboardWatcher()

    init() {
        Prefs.registerDefaults()
        store = ClipStore()
        if store.isSyncEnabled {
            // Silent pushes tell Core Data that another device changed the CloudKit zone.
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    var body: some Scene {
        WindowGroup {
            HistoryView(store: store, clipboard: clipboard)
                .environment(\.managedObjectContext, store.container.viewContext)
        }
    }
}

/// iOS doesn't let apps read the clipboard in the background, and reading it in the
/// foreground shows a paste prompt. `changeCount` and the `has…` checks don't prompt,
/// so they're used to offer a PasteButton (which also doesn't prompt) when something new
/// is on the clipboard.
@MainActor
final class ClipboardWatcher: ObservableObject {
    @Published private(set) var hasNewContent = false
    private var savedChangeCount = UserDefaults.standard.integer(forKey: "lastSavedChangeCount")

    func refresh() {
        let pasteboard = UIPasteboard.general
        hasNewContent = pasteboard.changeCount != savedChangeCount
            && (pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages)
    }

    /// Call after saving from, or writing to, the clipboard.
    func markSeen() {
        savedChangeCount = UIPasteboard.general.changeCount
        UserDefaults.standard.set(savedChangeCount, forKey: "lastSavedChangeCount")
        hasNewContent = false
    }
}
