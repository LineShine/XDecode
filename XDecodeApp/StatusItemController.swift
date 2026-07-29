import AppKit
import XDecodeCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var recentResults: [DecodeResult] = []
    var openWindow: (() -> Void)?
    var chooseFiles: (() -> Void)?

    func setEnabled(_ enabled: Bool) {
        if enabled, statusItem == nil {
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
        } else if !enabled, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func update(results: [DecodeResult]) {
        recentResults = Array(results.lazy.filter { $0.state != .skipped }.prefix(3))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "打开 XDecode", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(withTitle: "选择日志…", action: #selector(selectFiles), keyEquivalent: "")
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
        menu.addItem(withTitle: "退出 XDecode", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
    }

    @objc private func openApp() { openWindow?() }
    @objc private func selectFiles() { chooseFiles?() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
