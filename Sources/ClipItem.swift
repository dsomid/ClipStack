import CoreData

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
    /// Built in code since swiftc can't compile .xcdatamodeld bundles.
    static let shared: NSManagedObjectModel = {
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
        model.entities = [entity]
        return model
    }()
}
