import Foundation

protocol TaskRepository {
    func fetchTasks() -> [TaskItem]
}

