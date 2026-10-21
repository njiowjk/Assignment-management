import CoreData
import Foundation

/// ドメイン型とCore Dataを分離する。DBには課題情報と同期時刻だけを保存する。
@MainActor
final class CoreDataTaskRepository: TaskRepository {
    private let context: NSManagedObjectContext
    private let coordinator: NSPersistentStoreCoordinator

    init(storeURL: URL? = nil, inMemory: Bool = false) throws {
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

    func merge(_ tasks: [RemoteTask], source: TaskSource, at date: Date) throws -> SyncSummary {
        guard tasks.allSatisfy({ $0.source == source && !$0.externalID.isEmpty }),
              Set(tasks.map(\.externalID)).count == tasks.count else { throw AppFailure.invalidCalendar }
        do {
            let allRecords = try records("TaskRecord")
            var objects: [String: NSManagedObject] = [:]
            var existing: [String: TaskItem] = [:]
            for object in allRecords {
                let item = try decode(object)
                if item.source == source {
                    objects[item.externalID] = object
                    existing[item.externalID] = item
                }
            }

            var summary = SyncSummary()
            let incomingIDs = Set(tasks.map(\.externalID))
            for remote in tasks {
                var local: TaskItem
                if let previous = existing[remote.externalID] {
                    local = previous
                    if previous.deadline != remote.deadline { summary.deadlineChanges += 1 }
                    if previous.title != remote.title || previous.courseName != remote.courseName ||
                        previous.detail != remote.detail || previous.deadline != remote.deadline ||
                        previous.sourceURL != remote.sourceURL || previous.isRemovedFromSource ||
                        remote.isCompleted.map({ $0 != (previous.status == .completed) }) == true {
                        summary.updated += 1
                    }
                } else {
                    local = TaskItem(externalID: remote.externalID, source: source,
                                     courseName: remote.courseName, title: remote.title,
                                     deadline: remote.deadline, firstDetectedAt: date, lastSyncedAt: date)
                    summary.inserted += 1
                }
                local.courseName = remote.courseName
                local.title = remote.title
                local.detail = remote.detail
                local.deadline = remote.deadline
                local.sourceURL = remote.sourceURL
                local.lastSyncedAt = date
                local.isRemovedFromSource = false
                if let completed = remote.isCompleted {
                    local.completionIsKnown = true
                    local.status = completed ? .completed : (remote.deadline < date ? .overdue : .active)
                    local.completedAt = completed ? (local.completedAt ?? date) : nil
                } else if local.status != .completed {
                    local.status = remote.deadline < date ? .overdue : .active
                }
                let object = objects[remote.externalID] ?? NSEntityDescription.insertNewObject(
                    forEntityName: "TaskRecord", into: context)
                object.setValue(source.rawValue + ":" + remote.externalID, forKey: "key")
                object.setValue(try JSONEncoder().encode(local), forKey: "payload")
            }
            for (id, var item) in existing where !incomingIDs.contains(id) {
                // フィードの期間外・削除・取消のいずれでも、完了や物理削除とはみなさない。
                item.isRemovedFromSource = true
                objects[id]?.setValue(try JSONEncoder().encode(item), forKey: "payload")
                summary.missing += 1
            }
            let sync = try records("SourceSync").first { $0.value(forKey: "key") as? String == source.rawValue }
                ?? NSEntityDescription.insertNewObject(forEntityName: "SourceSync", into: context)
            sync.setValue(source.rawValue, forKey: "key")
            sync.setValue(date, forKey: "date")
            try context.save()
            return summary
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
