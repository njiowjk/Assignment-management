import AppKit
import SwiftUI

@main
struct UniversityTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel: HomeViewModel

    init() {
        if CommandLine.arguments.contains("--demo") {
            _viewModel = StateObject(wrappedValue: HomeViewModel(repository: SampleTaskRepository(), isDemo: true))
        } else {
            // DBを開けない場合に空のDBを作り直さず、保存エラーを表示する。
            _viewModel = StateObject(wrappedValue: HomeViewModel(repository: try? CoreDataTaskRepository()))
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView(viewModel: viewModel)
        }
        .defaultSize(width: 760, height: 680)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Swift Packageから起動した場合もキーボード入力を受ける通常のMacアプリとして扱う。
        NSApplication.shared.setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

