import CoreData
import Foundation

/// ドメイン型とCore Dataを分離する。DBには課題情報と同期時刻だけを保存する。
@MainActor
final class CoreDataTaskRepository: TaskRepository {
    private let context: NSManagedObjectContext
    private let coordinator: NSPersistentStoreCoordinator
    private let backend: BackendClient
    private var isMerging = false

    init(storeURL: URL? = nil, inMemory: Bool = false, backend: BackendClient = BackendClient()) throws {
        self.backend = backend
        let model = NSManagedObjectModel()
        model.entities = [
            Self.entity("TaskRecord", attributes: [("key", .stringAttributeType), ("payload", .binaryDataAttributeType)]),
            Self.entity("SourceSync", attributes: [("key", .stringAttributeType), ("date", .dateAttributeType)])
        ]
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        do {
            var url = storeURL
            if !inMemory {
                if url == nil {
                    let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                              in: .userDomainMask, appropriateFor: nil, create: true)
                    url = support.appendingPathComponent("UniversityTaskManager/tasks.sqlite")
                }
                if let directory = url?.deletingLastPathComponent() {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
            }
            try coordinator.addPersistentStore(ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType,
                                               configurationName: nil, at: inMemory ? nil : url,
                                               options: [NSMigratePersistentStoresAutomaticallyOption: true,
                                                         NSInferMappingModelAutomaticallyOption: true])
        } catch { throw AppFailure.storage }
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
    }

    func fetchTasks() throws -> [TaskItem] {
        do {
            return try records("TaskRecord").map { try decode($0) }
        } catch { throw AppFailure.storage }
    }

    func lastSyncedAt(for source: TaskSource) throws -> Date? {
        do {
            return try records("SourceSync").first { $0.value(forKey: "key") as? String == source.rawValue }?
                .value(forKey: "date") as? Date
        } catch { throw AppFailure.storage }
    }

    func merge(_ tasks: [RemoteTask], source: TaskSource, at date: Date) async throws -> SyncSummary {
        guard !isMerging else { throw AppFailure.storage }
        isMerging = true
        defer { isMerging = false }
        // DBのJSON形式・場所は維持し、更新ルールだけをTypeScriptに委譲する。
        let result = try await backend.merge(existing: fetchTasks(), tasks: tasks, source: source, at: date)
        try Task.checkCancellation()
        guard result.tasks.allSatisfy({ $0.source == source }),
              Set(result.tasks.map(\.externalID)).count == result.tasks.count else { throw AppFailure.backend }
        do {
            let allRecords = try records("TaskRecord")
            var objects: [String: NSManagedObject] = [:]
            for object in allRecords {
                let item = try decode(object)
                if item.source == source { objects[item.externalID] = object }
            }
            for item in result.tasks {
                let object = objects[item.externalID] ?? NSEntityDescription.insertNewObject(
                    forEntityName: "TaskRecord", into: context)
                object.setValue(source.rawValue + ":" + item.externalID, forKey: "key")
                object.setValue(try JSONEncoder().encode(item), forKey: "payload")
            }
            let sync = try records("SourceSync").first { $0.value(forKey: "key") as? String == source.rawValue }
                ?? NSEntityDescription.insertNewObject(forEntityName: "SourceSync", into: context)
            sync.setValue(source.rawValue, forKey: "key")
            sync.setValue(date, forKey: "date")
            try context.save()
            return result.summary
        } catch {
            context.rollback()
            throw AppFailure.storage
        }
    }

    private func records(_ entity: String) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
    }

    private func decode(_ object: NSManagedObject) throws -> TaskItem {
        guard let data = object.value(forKey: "payload") as? Data else { throw AppFailure.storage }
        return try JSONDecoder().decode(TaskItem.self, from: data)
    }

    private static func entity(_ name: String, attributes: [(String, NSAttributeType)]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = attributes.map { name, type in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = false
            return attribute
        }
        entity.uniquenessConstraints = [["key"]]
        return entity
    }
}
