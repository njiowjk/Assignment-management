import SwiftUI

@main
struct UniversityTaskManagerApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView(
                viewModel: HomeViewModel(
                    repository: SampleTaskRepository()
                )
            )
        }
        .defaultSize(width: 760, height: 680)
    }
}

