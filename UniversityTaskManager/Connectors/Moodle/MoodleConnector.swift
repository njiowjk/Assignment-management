import Foundation

struct MoodleConnector: TaskSourceConnector {
    let source: TaskSource = .moodle
    private let credentials: any CalendarCredentialStore
    private let backend: BackendClient
    private let existing: [TaskItem]

    init(credentials: any CalendarCredentialStore = KeychainService(),
         backend: BackendClient = BackendClient(), existing: [TaskItem] = []) {
        self.credentials = credentials
        self.backend = backend
        self.existing = existing
    }

    func fetchTasks() async throws -> [RemoteTask] {
        guard let url = try credentials.calendarURL() else { throw ConnectorError.notConfigured(source: source) }
        return try await backend.fetchMoodle(calendarURL: url, session: credentials.moodleSession(for: url), existing: existing)
    }
}

