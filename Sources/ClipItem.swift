import CoreData
import SwiftUI

enum ClipKind: String {
    case text, url, image, file
}

// CloudKit-compatible: every attribute is optional or has a default, no unique constraints.
@objc(ClipItem)
final class ClipItem: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var kindRaw: String
    @NSManaged var text: String?
    @NSManaged var urlString: String?
    /// Newline-separated, to avoid a transformable attribute.
    @NSManaged var filePathsRaw: String?
    @NSManaged var imageData: Data?
    @NSManaged var sourceAppBundleID: String?
    @NSManaged var contentHash: String
    @NSManaged var createdAt: Date
    @NSManaged var isPinned: Bool
    @NSManaged var categories: NSSet?

    var categoryList: [ClipCategory] {
        (categories?.allObjects as? [ClipCategory] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func isIn(_ category: ClipCategory) -> Bool {
        categories?.contains(category) ?? false
    }

    func toggle(_ category: ClipCategory) {
        let set = mutableSetValue(forKey: "categories")
        if set.contains(category) { set.remove(category) } else { set.add(category) }
    }

    var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var filePaths: [String] {
        get { filePathsRaw?.split(separator: "\n").map(String.init) ?? [] }
        set { filePathsRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date()
    }

    static func fetchRequest() -> NSFetchRequest<ClipItem> {
        NSFetchRequest<ClipItem>(entityName: "ClipItem")
    }
}

enum ClipModel {
    /// The current model. Built in code since swiftc can't compile .xcdatamodeld bundles.
    static let shared = make(withCategories: true)
    /// The 0.1.0 model, kept so existing stores can be migrated (see `migrateIfNeeded`).
    static let v1 = make(withCategories: false)

    private static func make(withCategories: Bool) -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "ClipItem"
        entity.managedObjectClassName = "ClipItem"

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = true,
                       default value: Any? = nil) -> NSAttributeDescription {
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.isOptional = optional
            attr.defaultValue = value
            return attr
        }

        let image = attribute("imageData", .binaryDataAttributeType)
        image.allowsExternalBinaryDataStorage = true
        let hash = attribute("contentHash", .stringAttributeType, optional: false, default: "")

        entity.properties = [
            attribute("id", .UUIDAttributeType, optional: false, default: UUID()),
            attribute("kindRaw", .stringAttributeType, optional: false, default: ClipKind.text.rawValue),
            attribute("text", .stringAttributeType),
            attribute("urlString", .stringAttributeType),
            attribute("filePathsRaw", .stringAttributeType),
            image,
            attribute("sourceAppBundleID", .stringAttributeType),
            hash,
            attribute("createdAt", .dateAttributeType, optional: false, default: Date.distantPast),
            attribute("isPinned", .booleanAttributeType, optional: false, default: false),
        ]
        entity.indexes = [
            NSFetchIndexDescription(name: "byHash", elements: [NSFetchIndexElementDescription(property: hash, collationType: .binary)]),
        ]

        let model = NSManagedObjectModel()
        guard withCategories else {
            model.entities = [entity]
            return model
        }

        let category = NSEntityDescription()
        category.name = "ClipCategory"
        category.managedObjectClassName = "ClipCategory"

        // Many-to-many with an inverse and optional ends, as CloudKit requires.
        let items = NSRelationshipDescription()
        items.name = "items"
        items.destinationEntity = entity
        items.minCount = 0
        items.maxCount = 0
        items.deleteRule = .nullifyDeleteRule
        items.isOptional = true
        let categories = NSRelationshipDescription()
        categories.name = "categories"
        categories.destinationEntity = category
        categories.minCount = 0
        categories.maxCount = 0
        categories.deleteRule = .nullifyDeleteRule
        categories.isOptional = true
        items.inverseRelationship = categories
        categories.inverseRelationship = items

        category.properties = [
            attribute("id", .UUIDAttributeType, optional: false, default: UUID()),
            attribute("name", .stringAttributeType, optional: false, default: ""),
            attribute("colorIndex", .integer16AttributeType, optional: false, default: 0),
            attribute("createdAt", .dateAttributeType, optional: false, default: Date.distantPast),
            items,
        ]
        entity.properties.append(categories)

        model.entities = [entity, category]
        return model
    }

    /// Lightweight migration can't find a code-built source model on its own, so a
    /// 0.1.0 store is migrated here with an inferred mapping before it's opened.
    static func migrateIfNeeded(storeURL: URL) {
        let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true]
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                  ofType: NSSQLiteStoreType, at: storeURL, options: options),
              !shared.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
              v1.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        else { return }

        let temp = storeURL.deletingLastPathComponent().appendingPathComponent("ClipStack-migrating.sqlite")
        do {
            let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v1, destinationModel: shared)
            let manager = NSMigrationManager(sourceModel: v1, destinationModel: shared)
            try manager.migrateStore(from: storeURL, sourceType: NSSQLiteStoreType, options: options,
                                     with: mapping, toDestinationURL: temp,
                                     destinationType: NSSQLiteStoreType, destinationOptions: options)
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: shared)
            try coordinator.replacePersistentStore(at: storeURL, destinationOptions: options,
                                                   withPersistentStoreFrom: temp, sourceOptions: options,
                                                   ofType: NSSQLiteStoreType)
            try coordinator.destroyPersistentStore(at: temp, ofType: NSSQLiteStoreType, options: options)
            // destroyPersistentStore empties the files but leaves them behind.
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: temp.path + suffix)
            }
        } catch {
            NSLog("ClipStack migration failed: %@", "\(error)")
        }
    }
}

/// A user-made group of clips, shown as a tab in the shelf.
@objc(ClipCategory)
final class ClipCategory: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var colorIndex: Int16
    @NSManaged var createdAt: Date
    @NSManaged var items: NSSet?

    static let palette: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]

    var color: Color { Self.palette[Int(colorIndex) % Self.palette.count] }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date()
    }

    static func fetchRequest() -> NSFetchRequest<ClipCategory> {
        NSFetchRequest<ClipCategory>(entityName: "ClipCategory")
    }
}
