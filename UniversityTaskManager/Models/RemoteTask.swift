import Foundation

/// LMS固有レスポンスをConnector内で変換した、永続化前の共通表現。
struct RemoteTask: Codable, Hashable, Sendable {
    let externalID: String
    let source: TaskSource
    let courseName: String
    let title: String
    let detail: String?
    let deadline: Date
    let sourceURL: URL?
    /// nilは提出状況を取得できないことを表す。ICSの有無から完了を推測しない。
    let isCompleted: Bool?
    let isRemovedFromSource: Bool?

    init(externalID: String, source: TaskSource, courseName: String, title: String,
         detail: String? = nil, deadline: Date, sourceURL: URL? = nil, isCompleted: Bool? = nil,
         isRemovedFromSource: Bool? = nil) {
        self.externalID = externalID
        self.source = source
        self.courseName = courseName
        self.title = title
        self.detail = detail
        self.deadline = deadline
        self.sourceURL = sourceURL
        self.isCompleted = isCompleted
        self.isRemovedFromSource = isRemovedFromSource
    }
}

