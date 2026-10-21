import Foundation

enum TaskStatus: String, Codable, Hashable, Sendable {
    case active
    case overdue
    case completed
    case unavailable
}

