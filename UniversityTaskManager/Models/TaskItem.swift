import Foundation

struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var externalID: String
    var source: TaskSource
    var courseName: String
    var title: String
    var detail: String?
    var deadline: Date
    var status: TaskStatus
    var sourceURL: URL?
    var firstDetectedAt: Date
    var lastSyncedAt: Date
    var completedAt: Date?
    var isRemovedFromSource: Bool

    init(
        id: UUID = UUID(),
        externalID: String,
        source: TaskSource,
        courseName: String,
        title: String,
        detail: String? = nil,
        deadline: Date,
        status: TaskStatus = .active,
        sourceURL: URL? = nil,
        firstDetectedAt: Date = .now,
        lastSyncedAt: Date = .now,
        completedAt: Date? = nil,
        isRemovedFromSource: Bool = false
    ) {
        self.id = id
        self.externalID = externalID
        self.source = source
        self.courseName = courseName
        self.title = title
        self.detail = detail
        self.deadline = deadline
        self.status = status
        self.sourceURL = sourceURL
        self.firstDetectedAt = firstDetectedAt
        self.lastSyncedAt = lastSyncedAt
        self.completedAt = completedAt
        self.isRemovedFromSource = isRemovedFromSource
    }

    var isVisibleOnHome: Bool {
        status != .completed
    }
}

