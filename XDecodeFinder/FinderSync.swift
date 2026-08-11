import AppKit
import FinderSync

final class FinderSyncExtension: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [FileManager.default.homeDirectoryForCurrentUser]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(),
              urls.contains(where: Self.isRegularFile) else { return nil }

        let menu = NSMenu(title: "XDecode")
        let item = NSMenuItem(title: "使用 XDecode 解密", action: #selector(decodeSelectedFiles), keyEquivalent: "")
        item.image = finderMenuImage()
            ?? NSImage(systemSymbolName: "xmark", accessibilityDescription: "XDecode")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func decodeSelectedFiles() {
        guard let selected = FIFinderSyncController.default().selectedItemURLs() else { return }
        let files = selected.filter(Self.isRegularFile)
        guard !files.isEmpty, let applicationURL = mainApplicationURL else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = true
        NSWorkspace.shared.open(
            files,
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func finderMenuImage() -> NSImage? {
        guard let imageURL = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: imageURL) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private var mainApplicationURL: URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.pathExtension == "app" ? url : nil
    }
}
