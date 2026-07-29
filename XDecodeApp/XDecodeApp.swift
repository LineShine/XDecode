import AppKit
import CoreServices
import SwiftUI
import XDecodeCore

@main
struct XDecodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("XDecode", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .frame(minWidth: 880, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开日志…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .pasteboard) {
                Button("剪切") { sendEditAction("cut:") }
                    .keyboardShortcut("x")
                Button("复制") { sendEditAction("copy:") }
                    .keyboardShortcut("c")
                Button("粘贴") { sendEditAction("paste:") }
                    .keyboardShortcut("v")
                Button("粘贴并匹配样式") { sendEditAction("pasteAsPlainText:") }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                Divider()
                Button("全选") { sendEditAction("selectAll:") }
                    .keyboardShortcut("a")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .frame(width: 620, height: 520)
        }
    }

    private func sendEditAction(_ name: String) {
        NSApp.sendAction(Selector(name), to: nil, from: nil)
    }
}

struct InitialWindowPresentationState {
    private(set) var isPending = true
    private var shouldSuppress = false

    mutating func receiveOpenURLs() -> Bool {
        guard isPending else { return false }
        shouldSuppress = true
        return true
    }

    mutating func resolve() -> Bool? {
        guard isPending else { return nil }
        isPending = false
        return !shouldSuppress
    }

    mutating func forcePresentation() {
        isPending = false
        shouldSuppress = false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hasFinishedLaunching = false
    private var initialWindowPresentation = InitialWindowPresentationState()
    private var initialWindowDecisionTask: Task<Void, Never>?
    private var isFlushingBeforeTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.prepareNotifications()
        AppModel.shared.setMainWindowPresenter { [weak self] in
            guard self != nil else { return }
            self?.presentMainWindow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
        AppModel.shared.launch()
        // LaunchServices can deliver open-URL events just after didFinishLaunching.
        // Keep SwiftUI's initial window transparent until that event has settled.
        initialWindowDecisionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self,
                  let shouldPresent = initialWindowPresentation.resolve() else { return }
            initialWindowDecisionTask = nil
            MainWindowVisibilityCoordinator.shared.completeLaunch(shouldPresent: shouldPresent)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if initialWindowPresentation.receiveOpenURLs() {
            MainWindowVisibilityCoordinator.shared.suppress()
        }
        AppModel.shared.enqueue(urls, origin: .openWith)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard hasFinishedLaunching else { return false }
        presentMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateLater }
        isFlushingBeforeTermination = true
        Task {
            await AppModel.shared.flushPendingPersistence()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func presentMainWindow() {
        initialWindowDecisionTask?.cancel()
        initialWindowDecisionTask = nil
        initialWindowPresentation.forcePresentation()
        MainWindowVisibilityCoordinator.shared.present()
    }
}

@MainActor
final class MainWindowVisibilityCoordinator {
    static let shared = MainWindowVisibilityCoordinator()

    private enum LaunchState {
        case pending
        case suppressed
        case presented
    }

    private var state: LaunchState = .pending
    private var window: NSWindow?

    private init() {}

    func attach(_ window: NSWindow) {
        self.window = window
        window.isReleasedWhenClosed = false
        applyState()
    }

    func suppress() {
        state = .suppressed
        applyState()
    }

    func completeLaunch(shouldPresent: Bool) {
        state = shouldPresent ? .presented : .suppressed
        applyState()
    }

    func present() {
        state = .presented
        guard let window else { return }
        NSApp.setActivationPolicy(.accessory)
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyState() {
        guard let window else { return }
        switch state {
        case .pending, .suppressed:
            window.alphaValue = 0
            if state == .suppressed {
                window.orderOut(nil)
            }
        case .presented:
            window.alphaValue = 1
        }
    }
}
