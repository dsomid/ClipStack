import Foundation
import CoreData
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A snapshot of one pasteboard change, read on the main thread.
struct CapturedClip: Sendable {
    let kind: ClipKind
    var text: String?
    var urlString: String?
    var filePaths: [String] = []
    var imageData: Data?
    let sourceAppBundleID: String?

    var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let urlString { hasher.update(data: Data(urlString.utf8)) }
        for path in filePaths { hasher.update(data: Data(path.utf8)) }
        if let imageData { hasher.update(data: imageData) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns the persistent container; all writes happen on one background context.
final class ClipStore: @unchecked Sendable {
    let container: NSPersistentCloudKitContainer
    let isSyncEnabled: Bool
    private let writeContext: NSManagedObjectContext
    private var remoteChangeObserver: NSObjectProtocol?
    private var dedupeScheduled = false
    private var expiryTimer: Timer?

    init(inMemory: Bool = false, cloudKitContainerID: String? = CloudSync.containerID) {
        container = NSPersistentCloudKitContainer(name: "ClipStack", managedObjectModel: ClipModel.shared)
        let description = container.persistentStoreDescriptions.first!
        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        }
        // History tracking stays on even when local-only, so enabling sync later
        // doesn't require switching it on for an existing store.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        isSyncEnabled = cloudKitContainerID != nil && !inMemory
        description.cloudKitContainerOptions = isSyncEnabled
            ? NSPersistentCloudKitContainerOptions(containerIdentifier: cloudKitContainerID!)
            : nil

        if let url = description.url, !inMemory {
            ClipModel.migrateIfNeeded(storeURL: url)
        }
        container.loadPersistentStores { _, error in
            if let error { fatalError("Failed to load store: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        writeContext = container.newBackgroundContext()
        writeContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        if isSyncEnabled {
            remoteChangeObserver = NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: nil
            ) { [weak self] _ in self?.scheduleDedupe() }
        }

        // Expire old items at launch and hourly, not only when something new is copied.
        applyHistoryLimit()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.applyHistoryLimit()
        }
    }

    /// Two devices copying the same thing each create a record; merge them once
    /// imports settle. Debounced because imports arrive in bursts.
    private func scheduleDedupe() {
        let context = writeContext
        context.perform {
            guard !self.dedupeScheduled else { return }
            self.dedupeScheduled = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                context.perform {
                    self.dedupeScheduled = false
                    Self.removeDuplicates(in: context)
                    Self.save(context)
                }
            }
        }
    }

    static func removeDuplicates(in context: NSManagedObjectContext) {
        let request = ClipItem.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        guard let items = try? context.fetch(request) else { return }
        var keepers: [String: ClipItem] = [:]
        for item in items {
            if let keeper = keepers[item.contentHash] {
                // Keep the newest copy; pinned or categorized anywhere carries over.
                keeper.isPinned = keeper.isPinned || item.isPinned
                if keeper.title == nil { keeper.title = item.title }
                keeper.mutableSetValue(forKey: "categories").union(item.categories as? Set<AnyHashable> ?? [])
                context.delete(item)
            } else {
                keepers[item.contentHash] = item
            }
        }
    }

    func insert(_ clip: CapturedClip) {
        let context = writeContext
        let limit = Self.historyLimit
        context.perform {
            let hash = clip.contentHash
            // Re-copying an existing item bumps it to the top instead of duplicating it.
            let existing = ClipItem.fetchRequest()
            existing.predicate = NSPredicate(format: "contentHash == %@", hash)
            existing.fetchLimit = 1
            if let item = try? context.fetch(existing).first {
                item.createdAt = Date()
            } else {
                let item = ClipItem(context: context)
                item.kind = clip.kind
                item.contentHash = hash
                item.sourceAppBundleID = clip.sourceAppBundleID
                item.text = clip.text
                item.urlString = clip.urlString
                item.filePaths = clip.filePaths
                item.imageData = clip.imageData.map(Self.pngData)
            }
            Self.save(context)
            // Prune only after saving: fetchOffset isn't applied to unsaved inserts,
            // so pruning first would delete the item we just added.
            Self.prune(in: context, keeping: limit)
            Self.save(context)
        }
    }

    /// Stores images as PNG; TIFF from the pasteboard is often 10x larger.
    private static func pngData(_ data: Data) -> Data {
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
        guard data.prefix(4) != pngSignature,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return data }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : data
    }

    private static func save(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do { try context.save() } catch { NSLog("ClipStack save failed: %@", "\(error)") }
    }

    private static var historyLimit: Int {
        max(1, UserDefaults.standard.integer(forKey: Prefs.historyLimit))
    }

    /// Trims history to the size and age limits, e.g. right after they change in Settings.
    func applyHistoryLimit() {
        let context = writeContext
        let limit = Self.historyLimit
        context.perform {
            Self.prune(in: context, keeping: limit)
            Self.save(context)
        }
    }

    private static func prune(in context: NSManagedObjectContext, keeping limit: Int) {
        let days = UserDefaults.standard.integer(forKey: Prefs.expiryDays)
        if days > 0 {
            let expired = ClipItem.fetchRequest()
            expired.predicate = NSPredicate(format: "isPinned == NO AND categories.@count == 0 AND createdAt < %@",
                                            Date(timeIntervalSinceNow: -Double(days) * 86_400) as NSDate)
            for item in (try? context.fetch(expired)) ?? [] { context.delete(item) }
        }
        let request = ClipItem.fetchRequest()
        // Pinned and categorized items are kept and don't count toward the limit.
        request.predicate = NSPredicate(format: "isPinned == NO AND categories.@count == 0")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchOffset = limit
        for item in (try? context.fetch(request)) ?? [] {
            context.delete(item)
        }
    }
}
