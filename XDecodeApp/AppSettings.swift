import Foundation
import XDecodeCore

enum FilenamePatternDefaults {
    static let xlog = "*.xlog"
    static let logan = "yyyy-MM-dd"
    static let mx = "*.mx"
    static let zip = #"^[A-Za-z0-9_-]*[A-Za-z0-9][_-][A-Za-z0-9][A-Za-z0-9_-]*\.zip$"#
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

    private struct StoredLoganCredentials: Codable {
        let key: Data
        let iv: Data
    }

    private enum Key {
        static let automaticEnabled = "automaticEnabled"
        static let defaultDownloadsMonitoringEnabled = "defaultDownloadsMonitoringEnabled"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let monitoredFolderBookmark = "monitoredFolderBookmark"
        static let monitoredFolderBookmarks = "monitoredFolderBookmarks"
        static let xlogProfiles = "xlogProfiles"
        static let loganProfiles = "loganProfiles"
        static let xlogPrivateKeys = "xlogPrivateKeys"
        static let loganCredentials = "loganCredentials"
        static let mxFilePattern = "mxFilePattern"
        static let zipPatternRules = "zipPatternRules"
    }

    private let defaults: UserDefaults
    private let createBookmark: BookmarkCreator
    private let resolveBookmark: BookmarkResolver
    private let defaultMonitoredFolderURL: URL?

    @Published var automaticEnabled: Bool { didSet { defaults.set(automaticEnabled, forKey: Key.automaticEnabled) } }
    @Published var launchAtLoginEnabled: Bool { didSet { defaults.set(launchAtLoginEnabled, forKey: Key.launchAtLoginEnabled) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }
    @Published var mxFilePattern: String { didSet { defaults.set(mxFilePattern, forKey: Key.mxFilePattern) } }
    @Published private(set) var defaultDownloadsMonitoringEnabled: Bool {
        didSet { defaults.set(defaultDownloadsMonitoringEnabled, forKey: Key.defaultDownloadsMonitoringEnabled) }
    }
    @Published private(set) var monitoredFolderBookmarks: [Data]
    @Published private(set) var xlogProfiles: [XlogProfile]
    @Published private(set) var loganProfiles: [LoganProfile]
    @Published private(set) var zipPatternRules: [ZipPatternRule]
    private var xlogPrivateKeys: [String: Data]
    private var loganCredentials: [String: StoredLoganCredentials]

    init(
        defaults: UserDefaults = .standard,
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
        self.defaultMonitoredFolderURL = defaultMonitoredFolderURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let hasStoredAutomaticSetting = defaults.object(forKey: Key.automaticEnabled) != nil
        let hasStoredDefaultDownloadsSetting = defaults.object(
            forKey: Key.defaultDownloadsMonitoringEnabled
        ) != nil
        automaticEnabled = hasStoredAutomaticSetting
            ? defaults.bool(forKey: Key.automaticEnabled)
            : true
        defaultDownloadsMonitoringEnabled = hasStoredDefaultDownloadsSetting
            ? defaults.bool(forKey: Key.defaultDownloadsMonitoringEnabled)
            : false
        launchAtLoginEnabled = defaults.object(forKey: Key.launchAtLoginEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.launchAtLoginEnabled)
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.notificationsEnabled)
        mxFilePattern = defaults.string(forKey: Key.mxFilePattern) ?? FilenamePatternDefaults.mx

        if let data = defaults.data(forKey: Key.zipPatternRules),
           let rules = try? JSONDecoder().decode([ZipPatternRule].self, from: data),
           !rules.isEmpty {
            zipPatternRules = rules
        } else {
            zipPatternRules = [ZipPatternRule()]
        }
        let storedBookmarks: [Data]
        if let bookmarks = defaults.array(forKey: Key.monitoredFolderBookmarks) as? [Data] {
            storedBookmarks = bookmarks
        } else if let legacyBookmark = defaults.data(forKey: Key.monitoredFolderBookmark) {
            storedBookmarks = [legacyBookmark]
        } else {
            storedBookmarks = []
        }

        let validStoredBookmarks = storedBookmarks.filter { bookmark in
            (try? resolveBookmark(bookmark)) != nil
        }
        monitoredFolderBookmarks = validStoredBookmarks
        let shouldEnableDefaultDownloads = !hasStoredDefaultDownloadsSetting
            && validStoredBookmarks.isEmpty
            && defaultMonitoredFolderURL != nil
        if shouldEnableDefaultDownloads {
            defaultDownloadsMonitoringEnabled = true
            automaticEnabled = true
            defaults.set(true, forKey: Key.automaticEnabled)
        }
        if !hasStoredDefaultDownloadsSetting {
            defaults.set(
                shouldEnableDefaultDownloads,
                forKey: Key.defaultDownloadsMonitoringEnabled
            )
        }
        xlogProfiles = defaults.data(forKey: Key.xlogProfiles)
            .flatMap { try? JSONDecoder().decode([XlogProfile].self, from: $0) } ?? []
        loganProfiles = defaults.data(forKey: Key.loganProfiles)
            .flatMap { try? JSONDecoder().decode([LoganProfile].self, from: $0) } ?? []
        xlogPrivateKeys = defaults.data(forKey: Key.xlogPrivateKeys)
            .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        loganCredentials = defaults.data(forKey: Key.loganCredentials)
            .flatMap {
                try? JSONDecoder().decode([String: StoredLoganCredentials].self, from: $0)
            } ?? [:]

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
        var urls = monitoredFolderBookmarks.compactMap { try? resolveBookmark($0) }
        if defaultDownloadsMonitoringEnabled, let defaultMonitoredFolderURL {
            urls.insert(defaultMonitoredFolderURL, at: 0)
        }

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return seen.insert(path).inserted
        }
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
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        monitoredFolderBookmarks.removeAll { storedBookmark in
            guard let storedURL = try? resolveBookmark(storedBookmark) else { return false }
            return storedURL.standardizedFileURL.resolvingSymlinksInPath() == normalizedURL
        }
        if isDefaultMonitoredFolder(url) {
            defaultDownloadsMonitoringEnabled = true
            persistMonitoredFolderBookmarks()
            return
        }

        let bookmark = try createBookmark(url)
        monitoredFolderBookmarks.append(bookmark)
        persistMonitoredFolderBookmarks()
    }

    func removeMonitoredFolder(_ url: URL) {
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        monitoredFolderBookmarks.removeAll { storedBookmark in
            guard let storedURL = try? resolveBookmark(storedBookmark) else { return true }
            return storedURL.standardizedFileURL.resolvingSymlinksInPath() == normalizedURL
        }
        if isDefaultMonitoredFolder(url) {
            defaultDownloadsMonitoringEnabled = false
        }
        persistMonitoredFolderBookmarks()
    }

    func setMonitoredFolder(_ url: URL) throws {
        defaultDownloadsMonitoringEnabled = false
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
        xlogPrivateKeys.removeValue(forKey: profile.id.uuidString)
        persistXlogProfiles()
        persistXlogPrivateKeys()
    }

    func saveXlogPrivateKey(_ privateKey: Data, for profileID: UUID) {
        xlogPrivateKeys[profileID.uuidString] = privateKey
        persistXlogPrivateKeys()
    }

    func xlogPrivateKey(for profileID: UUID) -> Data? {
        xlogPrivateKeys[profileID.uuidString]
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
        loganCredentials.removeValue(forKey: profile.id.uuidString)
        persistLoganProfiles()
        persistLoganCredentials()
    }

    func saveLoganCredentials(key: Data, iv: Data, for profileID: UUID) {
        loganCredentials[profileID.uuidString] = StoredLoganCredentials(key: key, iv: iv)
        persistLoganCredentials()
    }

    func loganCredentials(for profileID: UUID) -> (key: Data, iv: Data)? {
        guard let credentials = loganCredentials[profileID.uuidString] else { return nil }
        return (credentials.key, credentials.iv)
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

    private func persistXlogPrivateKeys() {
        defaults.set(try? JSONEncoder().encode(xlogPrivateKeys), forKey: Key.xlogPrivateKeys)
    }

    private func persistLoganCredentials() {
        defaults.set(try? JSONEncoder().encode(loganCredentials), forKey: Key.loganCredentials)
    }

    private func persistZipPatternRules() {
        defaults.set(try? JSONEncoder().encode(zipPatternRules), forKey: Key.zipPatternRules)
    }

    private func persistMonitoredFolderBookmarks() {
        defaults.set(monitoredFolderBookmarks, forKey: Key.monitoredFolderBookmarks)
        defaults.removeObject(forKey: Key.monitoredFolderBookmark)
    }

    private func isDefaultMonitoredFolder(_ url: URL) -> Bool {
        guard let defaultMonitoredFolderURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath()
            == defaultMonitoredFolderURL.standardizedFileURL.resolvingSymlinksInPath()
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
