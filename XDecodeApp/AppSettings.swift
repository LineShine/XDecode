import Foundation
import XDecodeCore

enum FilenamePatternDefaults {
    static let xlog = "*.xlog"
    static let logan = "yyyy-MM-dd"
    static let mx = "*.mx"
    static let zip = #"^[0-9]+_[0-9]+\.zip$"#
}

enum FilenamePattern {
    static func matches(_ pattern: String, url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let expression: String
        if trimmed.hasPrefix("^") {
            expression = trimmed
        } else {
            expression = "^\(friendlyExpression(for: trimmed))$"
        }

        guard let regex = try? NSRegularExpression(
            pattern: expression,
            options: [.caseInsensitive]
        ) else { return false }
        let fileName = url.lastPathComponent
        let range = NSRange(fileName.startIndex..., in: fileName)
        return regex.firstMatch(in: fileName, range: range) != nil
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
                let character = pattern[index]
                switch character {
                case "*": result += ".*"
                case "?": result += "."
                default:
                    result += NSRegularExpression.escapedPattern(for: String(character))
                }
                index = pattern.index(after: index)
            }
        }
        return result
    }
}

struct XlogProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var filePattern: String

    init(id: UUID = UUID(), name: String, filePattern: String = FilenamePatternDefaults.xlog) {
        self.id = id
        self.name = name
        self.filePattern = filePattern
    }

    func matches(_ url: URL) -> Bool {
        FilenamePattern.matches(filePattern, url: url)
    }
}

struct LoganProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var filePattern: String

    init(id: UUID = UUID(), name: String, filePattern: String = FilenamePatternDefaults.logan) {
        self.id = id
        self.name = name
        self.filePattern = filePattern
    }

    func matches(_ url: URL) -> Bool {
        FilenamePattern.matches(filePattern, url: url)
    }
}

struct ZipPatternRule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var pattern: String

    init(id: UUID = UUID(), pattern: String = FilenamePatternDefaults.zip) {
        self.id = id
        self.pattern = pattern
    }
}

@MainActor
final class AppSettings: ObservableObject {
    typealias BookmarkCreator = (URL) throws -> Data
    typealias BookmarkResolver = (Data) throws -> URL

    private enum Key {
        static let automaticEnabled = "automaticEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let menuBarEnabled = "menuBarEnabled"
        static let destructivePolicyConfirmed = "destructivePolicyConfirmed"
        static let monitoredFolderBookmark = "monitoredFolderBookmark"
        static let monitoredFolderBookmarks = "monitoredFolderBookmarks"
        static let xlogProfiles = "xlogProfiles"
        static let loganProfiles = "loganProfiles"
        static let mxFilePattern = "mxFilePattern"
        static let zipFilePattern = "zipFilePattern"
        static let zipPatternRules = "zipPatternRules"
    }

    private let defaults: UserDefaults
    private let createBookmark: BookmarkCreator
    private let resolveBookmark: BookmarkResolver

    @Published var automaticEnabled: Bool { didSet { defaults.set(automaticEnabled, forKey: Key.automaticEnabled) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }
    @Published var menuBarEnabled: Bool { didSet { defaults.set(menuBarEnabled, forKey: Key.menuBarEnabled) } }
    @Published var destructivePolicyConfirmed: Bool { didSet { defaults.set(destructivePolicyConfirmed, forKey: Key.destructivePolicyConfirmed) } }
    @Published var mxFilePattern: String { didSet { defaults.set(mxFilePattern, forKey: Key.mxFilePattern) } }
    @Published private(set) var monitoredFolderBookmarks: [Data]
    @Published private(set) var xlogProfiles: [XlogProfile]
    @Published private(set) var loganProfiles: [LoganProfile]
    @Published private(set) var zipPatternRules: [ZipPatternRule]

    init(
        defaults: UserDefaults = UserDefaults(suiteName: "group.com.flat.x.decode") ?? .standard,
        createBookmark: @escaping BookmarkCreator = AppSettings.makeBookmark,
        resolveBookmark: @escaping BookmarkResolver = AppSettings.resolveBookmark,
        defaultMonitoredFolderURL: URL? = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
    ) {
        self.defaults = defaults
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
        let hasStoredAutomaticSetting = defaults.object(forKey: Key.automaticEnabled) != nil
        automaticEnabled = hasStoredAutomaticSetting
            ? defaults.bool(forKey: Key.automaticEnabled)
            : true
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.notificationsEnabled)
        menuBarEnabled = defaults.object(forKey: Key.menuBarEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.menuBarEnabled)
        destructivePolicyConfirmed = defaults.bool(forKey: Key.destructivePolicyConfirmed)
        mxFilePattern = defaults.string(forKey: Key.mxFilePattern) ?? FilenamePatternDefaults.mx

        let storedZipPattern = defaults.string(forKey: Key.zipFilePattern)
        if let data = defaults.data(forKey: Key.zipPatternRules),
           let rules = try? JSONDecoder().decode([ZipPatternRule].self, from: data),
           !rules.isEmpty {
            zipPatternRules = rules
        } else if let storedZipPattern, storedZipPattern != "*_*.zip" {
            zipPatternRules = [ZipPatternRule(pattern: storedZipPattern)]
        } else {
            zipPatternRules = [ZipPatternRule()]
        }
        if let bookmarks = defaults.array(forKey: Key.monitoredFolderBookmarks) as? [Data],
           !bookmarks.isEmpty {
            monitoredFolderBookmarks = bookmarks
        } else if let legacyBookmark = defaults.data(forKey: Key.monitoredFolderBookmark) {
            monitoredFolderBookmarks = [legacyBookmark]
        } else if !hasStoredAutomaticSetting,
                  defaults.object(forKey: Key.monitoredFolderBookmarks) == nil,
                  defaults.object(forKey: Key.monitoredFolderBookmark) == nil,
                  let defaultMonitoredFolderURL,
                  let bookmark = try? createBookmark(defaultMonitoredFolderURL) {
            monitoredFolderBookmarks = [bookmark]
        } else {
            monitoredFolderBookmarks = []
        }
        xlogProfiles = defaults.data(forKey: Key.xlogProfiles)
            .flatMap { try? JSONDecoder().decode([XlogProfile].self, from: $0) } ?? []
        loganProfiles = defaults.data(forKey: Key.loganProfiles)
            .flatMap { try? JSONDecoder().decode([LoganProfile].self, from: $0) } ?? []

        var migratedLoganProfiles = false
        for index in loganProfiles.indices where loganProfiles[index].filePattern == "*.logan" {
            loganProfiles[index].filePattern = FilenamePatternDefaults.logan
            migratedLoganProfiles = true
        }
        if !hasStoredAutomaticSetting {
            defaults.set(automaticEnabled, forKey: Key.automaticEnabled)
        }
        persistZipPatternRules()
        persistMonitoredFolderBookmarks()
        if migratedLoganProfiles {
            defaults.set(try? JSONEncoder().encode(loganProfiles), forKey: Key.loganProfiles)
        }
    }

    var monitoredFolderURLs: [URL] {
        monitoredFolderBookmarks.compactMap { try? resolveBookmark($0) }
    }

    var monitoredFolderBookmark: Data? {
        monitoredFolderBookmarks.first
    }

    var monitoredFolderURL: URL? {
        monitoredFolderURLs.first
    }

    func matchesZipFile(_ url: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare(LogFormat.zip.rawValue) == .orderedSame else {
            return false
        }
        return zipPatternRules.contains { FilenamePattern.matches($0.pattern, url: url) }
    }

    var zipPatternSummary: String {
        zipPatternRules.map(\.pattern).filter { !$0.isEmpty }.joined(separator: "、")
    }

    func logFormat(for url: URL, includeZip: Bool = true) -> LogFormat? {
        if includeZip, matchesZipFile(url) { return .zip }
        if FilenamePattern.matches(FilenamePatternDefaults.xlog, url: url)
            || xlogProfiles.contains(where: { $0.matches(url) }) {
            return .xlog
        }
        if FilenamePattern.matches(mxFilePattern, url: url) { return .mx }
        if url.pathExtension.caseInsensitiveCompare(LogFormat.logan.rawValue) == .orderedSame
            || loganProfiles.contains(where: { $0.matches(url) })
            || (loganProfiles.isEmpty
                && FilenamePattern.matches(FilenamePatternDefaults.logan, url: url)) {
            return .logan
        }
        return nil
    }

    func addMonitoredFolder(_ url: URL) throws {
        let bookmark = try createBookmark(url)
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        monitoredFolderBookmarks.removeAll { storedBookmark in
            guard let storedURL = try? resolveBookmark(storedBookmark) else { return false }
            return storedURL.standardizedFileURL.resolvingSymlinksInPath() == normalizedURL
        }
        monitoredFolderBookmarks.append(bookmark)
        persistMonitoredFolderBookmarks()
    }

    func removeMonitoredFolder(_ url: URL) {
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        monitoredFolderBookmarks.removeAll { storedBookmark in
            guard let storedURL = try? resolveBookmark(storedBookmark) else { return true }
            return storedURL.standardizedFileURL.resolvingSymlinksInPath() == normalizedURL
        }
        persistMonitoredFolderBookmarks()
    }

    func setMonitoredFolder(_ url: URL) throws {
        monitoredFolderBookmarks.removeAll()
        try addMonitoredFolder(url)
    }

    func upsert(profile: XlogProfile) {
        if let index = xlogProfiles.firstIndex(where: { $0.id == profile.id }) {
            xlogProfiles[index] = profile
        } else {
            xlogProfiles.append(profile)
        }
        persistXlogProfiles()
    }

    func remove(profile: XlogProfile) {
        xlogProfiles.removeAll { $0.id == profile.id }
        persistXlogProfiles()
    }

    func upsert(profile: LoganProfile) {
        if let index = loganProfiles.firstIndex(where: { $0.id == profile.id }) {
            loganProfiles[index] = profile
        } else {
            loganProfiles.append(profile)
        }
        persistLoganProfiles()
    }

    func remove(profile: LoganProfile) {
        loganProfiles.removeAll { $0.id == profile.id }
        persistLoganProfiles()
    }

    func addZipPatternRule() {
        zipPatternRules.append(ZipPatternRule(pattern: ""))
        persistZipPatternRules()
    }

    func updateZipPatternRule(id: UUID, pattern: String) {
        guard let index = zipPatternRules.firstIndex(where: { $0.id == id }) else { return }
        zipPatternRules[index].pattern = pattern
        persistZipPatternRules()
    }

    func resetZipPatternRule(id: UUID) {
        updateZipPatternRule(id: id, pattern: FilenamePatternDefaults.zip)
    }

    func removeZipPatternRule(id: UUID) {
        guard zipPatternRules.count > 1 else {
            resetZipPatternRule(id: id)
            return
        }
        zipPatternRules.removeAll { $0.id == id }
        persistZipPatternRules()
    }

    private func persistXlogProfiles() {
        defaults.set(try? JSONEncoder().encode(xlogProfiles), forKey: Key.xlogProfiles)
    }

    private func persistLoganProfiles() {
        defaults.set(try? JSONEncoder().encode(loganProfiles), forKey: Key.loganProfiles)
    }

    private func persistZipPatternRules() {
        defaults.set(try? JSONEncoder().encode(zipPatternRules), forKey: Key.zipPatternRules)
    }

    private func persistMonitoredFolderBookmarks() {
        defaults.set(monitoredFolderBookmarks, forKey: Key.monitoredFolderBookmarks)
        defaults.removeObject(forKey: Key.monitoredFolderBookmark)
    }

    private nonisolated static func makeBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    private nonisolated static func resolveBookmark(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}
