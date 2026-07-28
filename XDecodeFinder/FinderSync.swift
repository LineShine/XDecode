import AppKit
import FinderSync

final class FinderSyncExtension: FIFinderSync {
    private struct LoganProfile: Decodable {
        let filePattern: String
    }

    private struct ZipPatternRule: Decodable {
        let pattern: String
    }

    private enum DefaultPattern {
        static let logan = "yyyy-MM-dd"
        static let mx = "*.mx"
        static let zip = #"^[0-9]+_[0-9]+\.zip$"#
    }

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [FileManager.default.homeDirectoryForCurrentUser]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(),
              urls.contains(where: Self.isSupported) else { return nil }

        let menu = NSMenu(title: "XDecode")
        let item = NSMenuItem(title: "使用 XDecode 解密", action: #selector(decodeSelectedFiles), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func decodeSelectedFiles() {
        guard let selected = FIFinderSyncController.default().selectedItemURLs() else { return }
        let supported = selected.filter(Self.isSupported)
        guard !supported.isEmpty, let applicationURL = mainApplicationURL else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            supported,
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }

    private static func isSupported(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        let defaults = UserDefaults(suiteName: "group.com.lingxiang.XDecode")
        if pathExtension == "xlog" { return true }
        if matches(defaults?.string(forKey: "mxFilePattern") ?? DefaultPattern.mx, url: url) {
            return true
        }
        if pathExtension == "logan" { return true }

        let profiles = defaults?.data(forKey: "loganProfiles")
            .flatMap { try? JSONDecoder().decode([LoganProfile].self, from: $0) } ?? []
        if profiles.contains(where: { matches($0.filePattern, url: url) }) { return true }
        if profiles.isEmpty, matches(DefaultPattern.logan, url: url) { return true }

        guard pathExtension == "zip" else { return false }
        let savedPatterns = defaults?.data(forKey: "zipPatternRules")
            .flatMap { try? JSONDecoder().decode([ZipPatternRule].self, from: $0) }
            .map { $0.map(\.pattern) }
        let legacyPattern = defaults?.string(forKey: "zipFilePattern")
        let patterns: [String]
        if let savedPatterns, !savedPatterns.isEmpty {
            patterns = savedPatterns
        } else if let legacyPattern, legacyPattern != "*_*.zip" {
            patterns = [legacyPattern]
        } else {
            patterns = [DefaultPattern.zip]
        }
        return patterns.contains { matches($0, url: url) }
    }

    private static func matches(_ pattern: String, url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expression = trimmed.hasPrefix("^")
            ? trimmed
            : "^\(friendlyExpression(for: trimmed))$"
        guard let regex = try? NSRegularExpression(
            pattern: expression,
            options: [.caseInsensitive]
        ) else { return false }
        let fileName = url.lastPathComponent
        return regex.firstMatch(
            in: fileName,
            range: NSRange(fileName.startIndex..., in: fileName)
        ) != nil
    }

    private static func friendlyExpression(for pattern: String) -> String {
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let remainder = pattern[index...]
            if remainder.hasPrefix("yyyy") {
                result += #"\d{4}"#
                index = pattern.index(index, offsetBy: 4)
            } else if remainder.hasPrefix("MM") || remainder.hasPrefix("dd") {
                result += #"\d{2}"#
                index = pattern.index(index, offsetBy: 2)
            } else {
                switch pattern[index] {
                case "*": result += ".*"
                case "?": result += "."
                default:
                    result += NSRegularExpression.escapedPattern(for: String(pattern[index]))
                }
                index = pattern.index(after: index)
            }
        }
        return result
    }

    private var mainApplicationURL: URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.pathExtension == "app" ? url : nil
    }
}
