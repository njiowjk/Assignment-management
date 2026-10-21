import Foundation

enum TaskSource: String, Codable, CaseIterable, Hashable, Sendable {
    case moodle = "Moodle"
    case webClass = "WebClass"

    var systemImageName: String {
        switch self {
        case .moodle:
            "graduationcap.fill"
        case .webClass:
            "building.columns.fill"
        }
    }
}

