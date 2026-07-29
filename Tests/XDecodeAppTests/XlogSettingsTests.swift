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

    @Test("Default rules classify logs and accept ZIP names with alphanumeric separators")
    func defaultPatternsAndFormats() throws {
        let suiteName = "XDecodeDefaultPatternTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.notificationsEnabled)
        #expect(settings.menuBarEnabled)
        #expect(settings.mxFilePattern == "*.mx")
        #expect(settings.zipPatternRules.map(\.pattern) == [FilenamePatternDefaults.zip])
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/demo.xlog")) == .xlog)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/demo.MX")) == .mx)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/2026-07-27")) == .logan)
        #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/2026-7-27")) == nil)
        let supportedZIPNames = [
            "1520_1785225610163.zip",
            "f9017f94-25e8-4366-b33b-ebc7d8af1d65.zip",
            "338911075_20059056_1logs.zip",
            "04c084ed-e28e-432e-bf15-aee001a8d9c2.zip",
            "_51500835_1logs.zip",
            "ded110c1-0bc0-46ff-8df0-d310cd8b98ef.zip",
        ]
        for fileName in supportedZIPNames {
            #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/\(fileName)")) == .zip)
        }

        let unsupportedZIPNames = [
            "user cache.zip",
            "user.cache.zip",
            "user@cache.zip",
            "日志_123.zip",
            "_.zip",
        ]
        for fileName in unsupportedZIPNames {
            #expect(settings.logFormat(for: URL(fileURLWithPath: "/tmp/\(fileName)")) == nil)
        }
    }

    @Test("General toggles default to enabled but explicit choices persist")
    func defaultToggleValues() throws {
        let suiteName = "XDecodeDefaultToggleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        #expect(initial.launchAtLoginEnabled)
        #expect(initial.notificationsEnabled)
        #expect(initial.menuBarEnabled)

        initial.launchAtLoginEnabled = false
        initial.notificationsEnabled = false
        initial.menuBarEnabled = false
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.launchAtLoginEnabled)
        #expect(!restored.notificationsEnabled)
        #expect(!restored.menuBarEnabled)
    }

    @Test("Automatic decoding defaults to Downloads and explicit removal persists")
    func automaticDecodeDefaults() throws {
        let suiteName = "XDecodeAutomaticDefaultsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let encode: AppSettings.BookmarkCreator = { Data($0.standardizedFileURL.path.utf8) }
        let decode: AppSettings.BookmarkResolver = { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let initial = AppSettings(
            defaults: defaults,
            createBookmark: encode,
            resolveBookmark: decode,
            defaultMonitoredFolderURL: downloads
        )
        #expect(initial.automaticEnabled)
        #expect(initial.monitoredFolderURLs == [downloads])
        #expect(initial.monitoredFolderBookmarks.isEmpty)
        #expect(defaults.bool(forKey: "automaticEnabled"))
        #expect(defaults.bool(forKey: "defaultDownloadsMonitoringEnabled"))

        initial.automaticEnabled = false
        initial.removeMonitoredFolder(downloads)
        let restored = AppSettings(
            defaults: defaults,
            createBookmark: encode,
            resolveBookmark: decode,
            defaultMonitoredFolderURL: downloads
        )
        #expect(!restored.automaticEnabled)
        #expect(restored.monitoredFolderURLs.isEmpty)

        defaults.removeObject(forKey: "monitoredFolderBookmarks")
        let legacyRestored = AppSettings(
            defaults: defaults,
            createBookmark: encode,
            resolveBookmark: decode,
            defaultMonitoredFolderURL: downloads
        )
        #expect(legacyRestored.monitoredFolderURLs.isEmpty)
    }

    @Test("Default Downloads resolves the sandbox symlink to the user directory")
    func defaultDownloadsResolvesSandboxSymlink() throws {
        let suiteName = "XDecodeDownloadsSymlinkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XDecodeDownloadsSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let downloads = temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let sandboxDownloads = temporaryDirectory
            .appendingPathComponent("Container", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandboxDownloads.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sandboxDownloads.path,
            withDestinationPath: downloads.path
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let settings = AppSettings(
            defaults: defaults,
            defaultMonitoredFolderURL: sandboxDownloads
        )

        #expect(settings.monitoredFolderURLs == [downloads])
    }

    @Test("Existing automatic setting without a valid folder migrates to Downloads")
    func migratesMissingAutomaticFolder() throws {
        let suiteName = "XDecodeAutomaticFolderMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "automaticEnabled")
        defaults.set([Data([0xFF])], forKey: "monitoredFolderBookmarks")
        let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let encode: AppSettings.BookmarkCreator = { Data($0.standardizedFileURL.path.utf8) }
        let decode: AppSettings.BookmarkResolver = { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let migrated = AppSettings(
            defaults: defaults,
            createBookmark: encode,
            resolveBookmark: decode,
            defaultMonitoredFolderURL: downloads
        )

        #expect(migrated.automaticEnabled)
        #expect(migrated.monitoredFolderURLs == [downloads])
        #expect(migrated.monitoredFolderBookmarks.isEmpty)
        #expect(defaults.bool(forKey: "defaultDownloadsMonitoringEnabled"))
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
        migrated.updateZipPatternRule(id: customRule.id, pattern: #"^release\..+\.zip$"#)
        migrated.mxFilePattern = "device-*.mx"
        let restored = AppSettings(defaults: defaults)
        #expect(restored.zipPatternRules.map(\.pattern) == [
            FilenamePatternDefaults.zip,
            #"^release\..+\.zip$"#,
        ])
        #expect(restored.mxFilePattern == "device-*.mx")
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/58321336_51471942.zip")))
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/release.prod.zip")))
        #expect(!restored.matchesZipFile(URL(fileURLWithPath: "/tmp/user cache.zip")))

        let defaultRule = try #require(restored.zipPatternRules.first)
        restored.removeZipPatternRule(id: defaultRule.id)
        #expect(!restored.matchesZipFile(URL(fileURLWithPath: "/tmp/123_456.zip")))
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/release.prod.zip")))

        let remainingRule = try #require(restored.zipPatternRules.first)
        restored.resetZipPatternRule(id: remainingRule.id)
        #expect(restored.zipPatternRules.map(\.pattern) == [FilenamePatternDefaults.zip])
        #expect(restored.matchesZipFile(URL(fileURLWithPath: "/tmp/123_456.zip")))
    }

    @Test("Previous numeric ZIP default migrates while custom rules remain unchanged")
    func migratesPreviousZipDefault() throws {
        let suiteName = "XDecodePreviousZipPatternTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let customPattern = #"^custom\..+\.zip$"#
        defaults.set(try JSONEncoder().encode([
            ZipPatternRule(pattern: FilenamePatternDefaults.previousZip),
            ZipPatternRule(pattern: customPattern),
        ]), forKey: "zipPatternRules")

        let migrated = AppSettings(defaults: defaults)
        #expect(migrated.zipPatternRules.map(\.pattern) == [
            FilenamePatternDefaults.zip,
            customPattern,
        ])

        let restored = AppSettings(defaults: defaults)
        #expect(restored.zipPatternRules.map(\.pattern) == [
            FilenamePatternDefaults.zip,
            customPattern,
        ])
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

    @Test("Xlog and Logan credentials persist in UserDefaults and follow profile deletion")
    func credentialPersistence() throws {
        let suiteName = "XDecodeCredentialPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xlogProfile = XlogProfile(name: "Xlog")
        let loganProfile = LoganProfile(name: "Logan")
        let settings = AppSettings(defaults: defaults, defaultMonitoredFolderURL: nil)
        settings.upsert(profile: xlogProfile)
        settings.upsert(profile: loganProfile)
        settings.saveXlogPrivateKey(Data([1, 2, 3]), for: xlogProfile.id)
        settings.saveLoganCredentials(
            key: Data("1234567890123456".utf8),
            iv: Data("abcdefghijklmnop".utf8),
            for: loganProfile.id
        )

        let restored = AppSettings(defaults: defaults, defaultMonitoredFolderURL: nil)
        #expect(restored.xlogPrivateKey(for: xlogProfile.id) == Data([1, 2, 3]))
        #expect(restored.loganCredentials(for: loganProfile.id)?.key == Data("1234567890123456".utf8))
        #expect(restored.loganCredentials(for: loganProfile.id)?.iv == Data("abcdefghijklmnop".utf8))

        restored.remove(profile: xlogProfile)
        restored.remove(profile: loganProfile)
        let removed = AppSettings(defaults: defaults, defaultMonitoredFolderURL: nil)
        #expect(removed.xlogPrivateKey(for: xlogProfile.id) == nil)
        #expect(removed.loganCredentials(for: loganProfile.id) == nil)
    }
}
