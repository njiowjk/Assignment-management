import AppKit
import SwiftUI

@main
struct UniversityTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel: HomeViewModel

    init() {
        let model: HomeViewModel
        if CommandLine.arguments.contains("--demo") {
            model = HomeViewModel(repository: SampleTaskRepository(), isDemo: true)
        } else {
            // DBを開けない場合に空のDBを作り直さず、保存エラーを表示する。
            model = HomeViewModel(repository: try? CoreDataTaskRepository())
        }
        _viewModel = StateObject(wrappedValue: model)
        applicationDelegate.viewModel = model
    }

    var body: some Scene {
        Window("課題", id: "main") {
            HomeView(viewModel: viewModel)
                .background(MainWindowRegistration())
                .onAppear { viewModel.startServices() }
        }
        .defaultSize(width: 760, height: 680)
        .commands { MainWindowCommands() }
        MenuBarExtra {
            MenuBarTaskView(viewModel: viewModel, coordinator: viewModel.coordinator)
        } label: {
            Label("\(viewModel.visibleTaskCount)", systemImage: "books.vertical")
                .accessibilityLabel("大学課題管理 未完了\(viewModel.visibleTaskCount)件")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var viewModel: HomeViewModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Swift Packageから起動した場合もキーボード入力を受ける通常のMacアプリとして扱う。
        NSApplication.shared.setActivationPolicy(.regular)
        MainWindowPresenter.shared.show()
        viewModel?.startServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { viewModel?.stopServices() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.shared.show()
        return true
    }

}

private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("課題一覧を開く") { openWindow(id: "main") }
                .keyboardShortcut("1", modifiers: .command)
        }
    }
}

@MainActor
private final class MainWindowPresenter {
    static let shared = MainWindowPresenter()
    private weak var window: NSWindow?

    func register(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // Registration happens when the native window actually exists, not in App.init.
        DispatchQueue.main.async { [weak self] in self?.show() }
    }

    func show(activate: Bool = true) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
        guard activate else { return }
        if #available(macOS 14, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct MainWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowRegistrationView { WindowRegistrationView() }
    func updateNSView(_ nsView: WindowRegistrationView, context: Context) {}
}

private final class WindowRegistrationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { MainWindowPresenter.shared.register(window) }
    }
}

