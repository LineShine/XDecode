import Foundation
import Testing
@testable import XDecodeApp

@Suite("File matching settings", .serialized)
@MainActor
struct XlogSettingsTests {
    @Test("Xlog profiles persist metadata and match wildcards case-insensitively")
    func profilePersistenceAndMatching() throws {
        let suiteName = "XDecodeXlogSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = XlogProfile(name: "WeChat", filePattern: "host_????.xlog")
        let settings = AppSettings(defaults: defaults)
        settings.upsert(profile: profile)

        #expect(profile.matches(URL(fileURLWithPath: "/tmp/HOST_2026.XLOG")))
        #expect(!profile.matches(URL(fileURLWithPath: "/tmp/host_26.xlog")))

        let restored = AppSettings(defaults: defaults)
        #expect(restored.xlogProfiles == [profile])

        restored.remove(profile: profile)
        #expect(AppSettings(defaults: defaults).xlogProfiles.isEmpty)
    }

    @Test("Default rules classify Xlog, MX, extensionless Logan, and numeric ZIP files")
    func defaultPatternsAndFormats() throws {
        let suiteName = "XDecodeDefaultPatternTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.notificationsEnabled)
        #expect(settings.menuBarEnabled)
        #expect(settings.mxFilePattern == "*.mx")
        #expect(settings.zipPatternRules.map(\.pattern) == [#"^[0-9]+_[0-9]+\.zip$"#])
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/demo.xlog")) == .xlog)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/demo.MX")) == .mx)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/2026-07-27")) == .logan)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/2026-7-27")) == nil)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/58321336_51471942.zip")) == .zip)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/user_cache.zip")) == nil)
    }

    @Test("Notification and menu bar defaults are enabled but explicit choices persist")
    func defaultToggleValues() throws {
        let suiteName = "XDecodeDefaultToggleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        #expect(initial.notificationsEnabled)
        #expect(initial.menuBarEnabled)

        initial.notificationsEnabled = false
        initial.menuBarEnabled = false
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.notificationsEnabled)
        #expect(!restored.menuBarEnabled)
    }

    @Test("ZIP rules migrate, support additions, persist, and match independently")
    func migratesLegacyDefaults() throws {
        let suiteName = "XDecodePatternMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("*_*.zip", forKey: "zipFilePattern")
        let oldProfile = LoganProfile(name: "Legacy", filePattern: "*.logan")
        defaults.set(try JSONEncoder().encode([oldProfile]), forKey: "loganProfiles")

        let migrated = AppSettings(defaults: defaults)
        #expect(migrated.zipPatternRules.map(\.pattern) == [FilenamePatternDefaults.zip])
        #expect(migrated.loganProfiles.first?.filePattern == FilenamePatternDefaults.logan)

        migrated.addZipPatternRule()
        let customRule = try #require(migrated.zipPatternRules.last)
        migrated.updateZipPatternRule(id: customRule.id, pattern: #"^release-.+\.zip$"#)
        migrated.mxFilePattern = "device-*.mx"
        let restored = AppSettings(defaults: defaults)
        #expect(restored.zipPatternRules.map(\.pattern) == [
            FilenamePatternDefaults.zip,
            #"^release-.+\.zip$"#,
        ])
        #expect(restored.mxFilePattern == "device-*.mx")
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/58321336_51471942.zip")))
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/release-prod.zip")))
        #expect(!restored.matchesZipFile(URL(fileURLWithPath: "/tmp/user_cache.zip")))

        let defaultRule = try #require(restored.zipPatternRules.first)
        restored.removeZipPatternRule(id: defaultRule.id)
        #expect(!restored.matchesZipFile(URL(fileURLWithPath: "/tmp/123_456.zip")))
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/release-prod.zip")))

        let remainingRule = try #require(restored.zipPatternRules.first)
        restored.resetZipPatternRule(id: remainingRule.id)
        #expect(restored.zipPatternRules.map(\.pattern) == [FilenamePatternDefaults.zip])
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/123_456.zip")))
    }

    @Test("Logan date templates and explicit regular expressions match full filenames")
    func dateTemplateAndRegexMatching() {
        #expect(FilenamePattern.matches(
            "yyyy-MM-dd",
            url: URL(fileURLWithPath: "/tmp/2026-07-27")
        ))
        #expect(!FilenamePattern.matches(
            "yyyy-MM-dd",
            url: URL(fileURLWithPath: "/tmp/prefix-2026-07-27")
        ))
        #expect(FilenamePattern.matches(
            #"^[0-9]+_[0-9]+\.zip$"#,
            url: URL(fileURLWithPath: "/tmp/12_34.zip")
        ))
        #expect(!FilenamePattern.matches(
            #"^[0-9]+_[0-9]+\.zip$"#,
            url: URL(fileURLWithPath: "/tmp/name_name.zip")
        ))
    }

    @Test("Multiple monitored folders persist, deduplicate, remove, and migrate the legacy bookmark")
    func monitoredFolderBookmarks() throws {
        let suiteName = "XDecodeMonitoredFoldersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/device-logs", isDirectory: true)
        let encode: AppSettings.BookmarkCreator = { Data($0.standardizedFileURL.path.utf8) }
        let decode: AppSettings.BookmarkResolver = { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        defaults.set(try encode(first), forKey: "monitoredFolderBookmark")

        let migrated = AppSettings(
            defaults: defaults,
            createBookmark: encode,
            resolveBookmark: decode
        )
        #expect(migrated.monitoredFolderURLs == [first])

        try migrated.addMonitoredFolder(second)
        try migrated.addMonitoredFolder(first)
        #expect(Set(migrated.monitoredFolderURLs) == Set([first, second]))
        #expect(migrated.monitoredFolderURLs.count == 2)

        let restored = AppSettings(
            defaults: defaults,
            createBookmark: encode,
            resolveBookmark: decode
        )
        #expect(Set(restored.monitoredFolderURLs) == Set([first, second]))
        restored.removeMonitoredFolder(first)
        #expect(restored.monitoredFolderURLs == [second])
    }

    @Test("Xlog keychain service supports add, update, and delete")
    func xlogKeychainLifecycle() throws {
        let service = "\(KeychainStore.xlogService).tests.\(UUID().uuidString)"
        let account = UUID().uuidString
        let store = KeychainStore(service: service)
        defer { store.remove(account: account) }

        try store.save(Data([1, 2, 3]), account: account)
        #expect(try store.read(account: account) == Data([1, 2, 3]))

        try store.save(Data([4, 5, 6]), account: account)
        #expect(try store.read(account: account) == Data([4, 5, 6]))

        store.remove(account: account)
        #expect(throws: (any Error).self) {
            try store.read(account: account)
        }
    }
}
