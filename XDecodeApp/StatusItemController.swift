import AppKit
import XDecodeCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var recentResults: [DecodeResult] = []
    private var isCheckingForUpdates = false
    var openWindow: (() -> Void)?
    var chooseFiles: (() -> Void)?
    var checkForUpdates: (() -> Void)?
    var openSettings: (() -> Void)?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "XDecode")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("XDecode")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func update(results: [DecodeResult]) {
        recentResults = Array(results.lazy.filter { $0.state != .skipped }.prefix(3))
    }

    func setCheckingForUpdates(_ isChecking: Bool) {
        isCheckingForUpdates = isChecking
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "打开 XDecode", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(withTitle: "选择日志…", action: #selector(selectFiles), keyEquivalent: "")
        menu.addItem(.separator())
        let updateItem = menu.addItem(
            withTitle: isCheckingForUpdates ? "正在检查更新…" : "检查更新",
            action: #selector(checkUpdate),
            keyEquivalent: ""
        )
        updateItem.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "检查更新"
        )
        updateItem.isEnabled = !isCheckingForUpdates
        let settingsItem = menu.addItem(
            withTitle: "设置",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "设置"
        )
        if !recentResults.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "最近任务", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for result in recentResults {
                let title = NotificationManager.presentation(for: result).title
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
    }

    @objc private func openApp() { openWindow?() }
    @objc private func selectFiles() { chooseFiles?() }
    @objc private func checkUpdate() { checkForUpdates?() }
    @objc private func showSettings() { openSettings?() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
