import Foundation

/// LMS固有レスポンスをConnector内で変換した、永続化前の共通表現。
struct RemoteTask: Hashable, Sendable {
    let externalID: String
    let source: TaskSource
    let courseName: String
    let title: String
    let detail: String?
    let deadline: Date
    let sourceURL: URL?
    let isCompleted: Bool
}

