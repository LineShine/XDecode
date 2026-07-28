import AppKit
import SwiftUI
import XDecodeCore

@main
struct XDecodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.prepareNotifications()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.showMainWindow()
        AppModel.shared.enqueue(urls, origin: .openWith)
    }
}
