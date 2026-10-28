import Foundation
import CoreData
import Security

/// iCloud sync is on only when the app is signed with an iCloud container entitlement,
/// which requires an Apple Developer provisioning profile (see build.sh and build-ios.sh).
enum CloudSync {
    static let containerEntitlement = "com.apple.developer.icloud-container-identifiers"

    /// The first iCloud container this binary is entitled to, or nil for local-only.
    static let containerID: String? = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, containerEntitlement as CFString, nil)
        else { return nil }
        return (value as? [String])?.first
        #else
        // iOS apps can't read their own entitlements, so the build marks iCloud-signed
        // builds in Info.plist (CloudKit traps without the entitlement).
        return Bundle.main.object(forInfoDictionaryKey: "ClipStackCloudKitContainer") as? String
        #endif
    }()
}

/// Observable sync state for Settings.
@MainActor
final class SyncStatus: ObservableObject {
    enum State: Equatable {
        case disabled
        case idle(lastSync: Date?)
        case syncing
        case failed(String)
    }

    @Published private(set) var state: State
    private var observer: NSObjectProtocol?

    init(container: NSPersistentContainer, enabled: Bool) {
        state = enabled ? .idle(lastSync: nil) : .disabled
        guard enabled else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            state = .syncing
        } else if let error = event.error {
            state = .failed(error.localizedDescription)
        } else {
            state = .idle(lastSync: event.endDate)
        }
    }
}
