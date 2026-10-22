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
        WindowGroup("課題", id: "main") {
            HomeView(viewModel: viewModel)
                .background(MainWindowRegistration())
                .task {
                    await viewModel.loadCredentials()
                    guard !Task.isCancelled else { return }
                    MainWindowPresenter.shared.show()
                    await viewModel.syncAll()
                }
        }
        .defaultSize(width: 760, height: 680)
        .commands { MainWindowCommands() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Swift Packageから起動した場合もキーボード入力を受ける通常のMacアプリとして扱う。
        NSApplication.shared.setActivationPolicy(.regular)
        MainWindowPresenter.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.shared.show()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApplication.shared.keyWindow == nil { MainWindowPresenter.shared.show(activate: false) }
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

