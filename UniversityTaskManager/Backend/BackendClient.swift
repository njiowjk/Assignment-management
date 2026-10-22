import Foundation

/// macOS側はJSON転送だけを担当し、取得・解析・差分判定をTypeScriptへ委譲する。
struct BackendClient: Sendable {
    private let resourceDirectory: URL?

    init(resourceDirectory: URL? = nil) { self.resourceDirectory = resourceDirectory }

    private struct FetchRequest: Encodable, Sendable {
        let version = 1
        let command = "fetchMoodle"
        let calendarURL: String
        let timeZone: String
        let session: MoodleSession?
        let existing: [TaskItem]
    }
    private struct ParseRequest: Encodable, Sendable {
        let version = 1
        let command = "parseICS"
        let calendarBase64: String
        let timeZone: String
    }
    private struct WebClassRequest: Encodable, Sendable {
        let version = 1
        let command = "fetchWebClass"
        let session: WebClassSession?
    }
    private struct MergeRequest: Encodable, Sendable {
        let version = 1
        let command = "merge"
        let existing: [TaskItem]
        let tasks: [RemoteTask]
        let source: TaskSource
        let now: Date
    }
    private struct PolicyRequest: Encodable, Sendable {
        let version = 1
        let command = "syncPolicy"
        let now: Date
        let intervalSeconds: Int
        let trigger: SyncTrigger
        let states: [SyncPolicyState]
        let enabled: [TaskSource]
        let event: SyncPolicyEvent?
    }
    private struct Envelope<Value: Decodable>: Decodable {
        struct Failure: Decodable { let code: String }
        let version: Int
        let ok: Bool
        let result: Value?
        let error: Failure?
    }
    private struct NotificationRequest: Encodable, Sendable {
        let version = 1
        let command = "notificationPlan"
        let tasks: [TaskItem]
        let syncedSources: [TaskSource]
        let preferences: NotificationPreferences
        let state: NotificationState
        let now: Date
    }

    struct MergeResult: Codable, Sendable {
        let tasks: [TaskItem]
        let summary: SyncSummary
    }

    func fetchMoodle(calendarURL: URL, timeZone: String = TimeZone.autoupdatingCurrent.identifier,
                     session: MoodleSession? = nil, existing: [TaskItem] = []) async throws -> [RemoteTask] {
        try await request(FetchRequest(calendarURL: calendarURL.absoluteString, timeZone: timeZone, session: session, existing: existing))
    }

    func parseICS(_ data: Data, timeZone: String) async throws -> [RemoteTask] {
        try await request(ParseRequest(calendarBase64: data.base64EncodedString(), timeZone: timeZone))
    }

    func fetchWebClass(session: WebClassSession? = nil) async throws -> [RemoteTask] {
        try await request(WebClassRequest(session: session))
    }

    func merge(existing: [TaskItem], tasks: [RemoteTask], source: TaskSource, at date: Date) async throws -> MergeResult {
        try await request(MergeRequest(existing: existing, tasks: tasks, source: source, now: date))
    }

    func syncPolicy(states: [SyncPolicyState], enabled: [TaskSource], intervalSeconds: Int,
                    trigger: SyncTrigger, event: SyncPolicyEvent? = nil, now: Date = .now) async throws -> SyncPolicyPlan {
        try await request(PolicyRequest(now: now, intervalSeconds: intervalSeconds, trigger: trigger,
                                      states: states, enabled: enabled, event: event))
    }

    func notificationPlan(tasks: [TaskItem], syncedSources: [TaskSource], preferences: NotificationPreferences,
                          state: NotificationState, now: Date = .now) async throws -> NotificationPlan {
        try await request(NotificationRequest(tasks: tasks, syncedSources: syncedSources, preferences: preferences, state: state, now: now))
    }

    private func request<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ value: Input) async throws -> Output {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let input = try encoder.encode(value)
        guard input.count <= 32 * 1_024 * 1_024 else { throw AppFailure.tooLarge }
        let configuration = try BackendConfiguration.resolve(resourceDirectory: resourceDirectory)
        let operation = BackendOperation()
        let data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try operation.run(input, configuration: configuration)
            }.value
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let response: Envelope<Output>
        do { response = try decoder.decode(Envelope<Output>.self, from: data) }
        catch { throw AppFailure.backend }
        guard response.version == 1 else { throw AppFailure.backend }
        if response.ok, let result = response.result { return result }
        switch response.error?.code {
        case "moodleLoginRequired": throw AppFailure.moodleLoginRequired
        case "webClassLoginRequired": throw AppFailure.webClassLoginRequired
        case "invalidWebClassData": throw AppFailure.invalidWebClassData
        case "notConfigured": throw ConnectorError.notConfigured(source: .webClass)
        case "invalidURL": throw AppFailure.invalidURL
        case "invalidCalendar": throw AppFailure.invalidCalendar
        case "unsupportedCalendar": throw AppFailure.unsupportedCalendar
        case "network": throw AppFailure.network
        case "authentication": throw AppFailure.authentication
        case "server": throw AppFailure.server
        case "tooLarge": throw AppFailure.tooLarge
        default: throw AppFailure.backend
        }
    }
}

private struct BackendConfiguration: Sendable {
    let node: URL
    let worker: URL

    static func resolve(resourceDirectory: URL?) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        let nodePath: String
        if resourceDirectory == nil, let testDirectory = environment["ASSIGNMENT_BACKEND_DIR"],
           let testNode = environment["ASSIGNMENT_NODE_EXECUTABLE"] {
            directory = URL(fileURLWithPath: testDirectory)
            nodePath = testNode
        } else {
            guard let resourceURL = resourceDirectory ?? Bundle.main.resourceURL else { throw AppFailure.backend }
            directory = resourceURL.appendingPathComponent("Backend")
            struct Runtime: Decodable { let nodeExecutable: String }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.json")),
                  let runtime = try? JSONDecoder().decode(Runtime.self, from: data) else { throw AppFailure.backend }
            nodePath = runtime.nodeExecutable
        }
        let node = URL(fileURLWithPath: nodePath)
        let worker = directory.appendingPathComponent("worker.mjs")
        guard nodePath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.isReadableFile(atPath: worker.path) else { throw AppFailure.backend }
        return Self(node: node, worker: worker)
    }
}

/// 子プロセスをメインスレッド外で待つ。キャンセル・タイムアウトで子も終了する。
private final class BackendOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func cancel(timeout: Bool = false) {
        lock.lock()
        if !cancelled { cancelled = true; timedOut = timeout }
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    private func cancellationError() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        if !cancelled { return nil }
        return timedOut ? AppFailure.backend : CancellationError()
    }

    func run(_ input: Data, configuration: BackendConfiguration) throws -> Data {
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = configuration.node
        child.arguments = [configuration.worker.path]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        // Nodeの起動オプションや診断出力の環境設定を継承しない。
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TZ": "UTC"]

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() }
        catch { lock.unlock(); throw AppFailure.backend }
        lock.unlock()

        let timeout = DispatchWorkItem { [weak self] in self?.cancel(timeout: true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: timeout)
        defer {
            timeout.cancel()
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            var output = Data()
            while let chunk = try stdout.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                guard output.count + chunk.count <= 32 * 1_024 * 1_024 else { throw AppFailure.tooLarge }
                output.append(chunk)
            }
            child.waitUntilExit()
            if let error = cancellationError() { throw error }
            guard child.terminationStatus == 0 else { throw AppFailure.backend }
            return output
        } catch {
            if let cancellation = cancellationError() { throw cancellation }
            if let failure = error as? AppFailure { throw failure }
            throw AppFailure.backend
        }
    }
}
