import AppKit
import ServiceManagement
import SwiftUI
import XDecodeCore

enum SidebarSection: String, CaseIterable, Identifiable {
    case decode = "解密"
    case history = "历史记录"
    case monitor = "监控文件夹"
    case finder = "Finder 右键"
    case settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .decode: "sparkles"
        case .history: "clock.arrow.circlepath"
        case .monitor: "folder.badge.gearshape"
        case .finder: "cursorarrow.click"
        case .settings: "gearshape"
        }
    }
}

struct ScopedFolderAccess {
    let directoryURL: URL
    private let shouldStop: Bool

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        shouldStop = directoryURL.startAccessingSecurityScopedResource()
    }

    func stop() {
        if shouldStop {
            directoryURL.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
final class FolderAccessStore {
    typealias BookmarkCreator = (URL) throws -> Data
    typealias BookmarkResolver = (Data) throws -> (url: URL, isStale: Bool)

    static let defaultKey = "authorizedFolderBookmarks"

    private let defaults: UserDefaults
    private let storageKey: String
    private let createBookmark: BookmarkCreator
    private let resolveBookmark: BookmarkResolver
    private let staticallyAuthorizedDirectories: [URL]
    private var bookmarks: [Data]

    init(
        defaults: UserDefaults = UserDefaults(suiteName: SharedContainer.identifier) ?? .standard,
        storageKey: String = FolderAccessStore.defaultKey,
        staticallyAuthorizedDirectories: [URL] = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ),
        createBookmark: @escaping BookmarkCreator = FolderAccessStore.makeBookmark,
        resolveBookmark: @escaping BookmarkResolver = FolderAccessStore.resolveBookmark
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
        self.staticallyAuthorizedDirectories = staticallyAuthorizedDirectories.map(Self.normalized)
        bookmarks = defaults.array(forKey: storageKey)?.compactMap { $0 as? Data } ?? []
    }

    func remember(_ directoryURL: URL) throws {
        let normalizedURL = Self.normalized(directoryURL)
        let bookmark = try createBookmark(directoryURL)
        bookmarks.removeAll { storedBookmark in
            guard let storedURL = try? resolveBookmark(storedBookmark).url else { return false }
            return Self.normalized(storedURL) == normalizedURL
        }
        bookmarks.append(bookmark)
        persist()
    }

    func importBookmark(_ bookmark: Data) {
        guard let importedURL = try? resolveBookmark(bookmark).url else { return }
        let normalizedURL = Self.normalized(importedURL)
        guard !bookmarks.contains(where: { storedBookmark in
            guard let storedURL = try? resolveBookmark(storedBookmark).url else { return false }
            return Self.normalized(storedURL) == normalizedURL
        }) else { return }

        bookmarks.append(bookmark)
        persist()
    }

    func beginAccess(to fileURL: URL) -> ScopedFolderAccess? {
        guard let directoryURL = authorizedDirectory(containing: fileURL) else { return nil }
        return ScopedFolderAccess(directoryURL: directoryURL)
    }

    func authorizedDirectory(containing fileURL: URL) -> URL? {
        var bestMatch: URL?
        var bestComponentCount = -1
        var bookmarksChanged = false

        for directoryURL in staticallyAuthorizedDirectories
            where Self.contains(fileURL: fileURL, directoryURL: directoryURL) {
            let componentCount = directoryURL.pathComponents.count
            if componentCount > bestComponentCount {
                bestMatch = directoryURL
                bestComponentCount = componentCount
            }
        }

        for index in bookmarks.indices {
            guard var resolved = try? resolveBookmark(bookmarks[index]) else { continue }

            if resolved.isStale, let refreshed = refreshBookmark(for: resolved.url) {
                bookmarks[index] = refreshed
                bookmarksChanged = true
                if let refreshedResolution = try? resolveBookmark(refreshed) {
                    resolved = refreshedResolution
                }
            }

            let normalizedDirectory = Self.normalized(resolved.url)
            guard Self.contains(fileURL: fileURL, directoryURL: normalizedDirectory) else { continue }
            let componentCount = normalizedDirectory.pathComponents.count
            if componentCount > bestComponentCount {
                bestMatch = resolved.url
                bestComponentCount = componentCount
            }
        }

        if bookmarksChanged { persist() }
        return bestMatch
    }

    static func contains(fileURL: URL, directoryURL: URL) -> Bool {
        let fileComponents = normalized(fileURL).pathComponents
        let directoryComponents = normalized(directoryURL).pathComponents
        guard directoryComponents.count <= fileComponents.count else { return false }
        return Array(fileComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    nonisolated static func makeBookmark(for directoryURL: URL) throws -> Data {
        try directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    nonisolated static func resolveBookmark(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    private func refreshBookmark(for directoryURL: URL) -> Data? {
        let didStart = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { directoryURL.stopAccessingSecurityScopedResource() }
        }
        return try? createBookmark(directoryURL)
    }

    private func persist() {
        defaults.set(bookmarks, forKey: storageKey)
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var selectedSection: SidebarSection = .decode
    @Published private(set) var results: [DecodeResult] = []
    @Published private(set) var activeTaskCount = 0
    @Published var bannerMessage: String?

    let settings = AppSettings()
    private let loganKeychain = KeychainStore(service: KeychainStore.loganService)
    private let xlogKeychain = KeychainStore(service: KeychainStore.xlogService)
    private let historyStore = HistoryStore()
    private let monitor = FolderMonitor()
    private let suppressionStore = AutomaticDecodeSuppressionStore()
    private let stabilityGate = FileStabilityGate()
    private let notifications = NotificationManager()
    private let statusItem = StatusItemController()
    private let folderAccess = FolderAccessStore()
    private var pendingFolderAccessRequests: [(URL, DecodeOrigin)] = []
    private var folderAuthorizationInProgress = false
    private var activeSourcePaths = Set<String>()
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var mainWindowPresenter: (() -> Void)?

    private lazy var decoderResolver = StandardDecoderResolver.make(
            xlogCredentials: { [weak self] url in
                guard let self else { return [] }
                return await self.xlogCredentials(for: url)
            },
            loganCredentials: { [weak self] url in
                guard let self else { throw DecodeError.missingCredentials(.logan) }
                return try await self.loganCredentials(for: url)
            }
        )
    private lazy var coordinator = DecodeCoordinator(decoderResolver: decoderResolver)
    private lazy var zipCoordinator = ZipDecodeCoordinator(
        decoderResolver: decoderResolver,
        entryFormatResolver: { [weak self] url in
            await MainActor.run {
                self?.settings.logFormat(for: url, includeZip: false)
            }
        },
        publicationTracker: suppressionStore
    )

    private init() {
        settings.monitoredFolderBookmarks.forEach(folderAccess.importBookmark)
        monitor.onNewFile = { [weak self] url in
            guard let self else { return }
            Task {
                if await self.suppressionStore.consumeIfRegistered(url) { return }
                if await self.stabilityGate.waitUntilStable(url) {
                    await MainActor.run {
                        guard self.settings.automaticEnabled else { return }
                        self.enqueue([url], origin: .automatic)
                    }
                }
            }
        }
        statusItem.openWindow = { [weak self] in self?.showMainWindow() }
        statusItem.chooseFiles = { [weak self] in self?.chooseFiles() }
    }

    func launch() {
        setLaunchAtLoginEnabled(settings.launchAtLoginEnabled)
        if settings.notificationsEnabled {
            requestNotificationAuthorization(showFailure: false)
        }
        Task {
            results = await historyStore.load()
            refreshStatusItem()
            guard settings.automaticEnabled else { return }
            guard !settings.monitoredFolderURLs.isEmpty else {
                settings.automaticEnabled = false
                bannerMessage = "无法访问默认下载目录，请重新添加监控文件夹。"
                return
            }
            startMonitoring()
        }
    }

    func prepareNotifications() {
        notifications.configure()
    }

    func setMainWindowPresenter(_ presenter: @escaping () -> Void) {
        mainWindowPresenter = presenter
    }

    func enqueue(_ urls: [URL], origin: DecodeOrigin) {
        let supported = urls.filter(isSupportedInput)
        guard !supported.isEmpty else {
            guard origin != .automatic else { return }
            if urls.contains(where: { $0.pathExtension.lowercased() == "zip" }) {
                bannerMessage = "ZIP 文件名不匹配设置中的任一正则规则：\(settings.zipPatternSummary)"
            } else {
                bannerMessage = "请选择 xlog、mx、Logan 或符合规则的 ZIP 文件"
            }
            return
        }

        let zipInputs = supported.filter { settings.logFormat(for: $0) == .zip }
        zipInputs.forEach { prepareToProcess($0, origin: origin) }
        let destructiveInputs = supported.filter { settings.logFormat(for: $0) != .zip }
        guard !destructiveInputs.isEmpty else { return }

        destructiveInputs.forEach { prepareToProcess($0, origin: origin) }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK else { return }
        enqueue(panel.urls, origin: .filePicker)
    }

    func chooseMonitoredFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加监控文件夹"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            for url in panel.urls {
                try settings.addMonitoredFolder(url)
            }
            settings.monitoredFolderBookmarks.forEach(folderAccess.importBookmark)
            setAutomaticEnabled(true)
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func removeMonitoredFolder(_ url: URL) {
        settings.removeMonitoredFolder(url)
        guard !settings.monitoredFolderURLs.isEmpty else {
            setAutomaticEnabled(false)
            return
        }
        if settings.automaticEnabled { startMonitoring() }
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.automaticEnabled = false
            monitor.stop()
            return
        }
        guard !settings.monitoredFolderURLs.isEmpty else {
            chooseMonitoredFolders()
            return
        }
        enableAutomaticMonitoring()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationAuthorizationTask?.cancel()
        settings.notificationsEnabled = enabled
        guard enabled else {
            return
        }
        requestNotificationAuthorization(showFailure: true)
    }

    private func requestNotificationAuthorization(showFailure: Bool) {
        notificationAuthorizationTask = Task { [weak self] in
            guard let self else { return }
            let granted = await notifications.requestAuthorization()
            guard !Task.isCancelled else { return }
            settings.notificationsEnabled = granted
            if !granted, showFailure {
                bannerMessage = "系统未授予通知权限，请在系统设置的通知页面允许 XDecode。"
            }
        }
    }

    func setMenuBarEnabled(_ enabled: Bool) {
        settings.menuBarEnabled = enabled
        refreshStatusItem()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else {
                switch service.status {
                case .notRegistered, .notFound:
                    break
                case .enabled, .requiresApproval:
                    try service.unregister()
                @unknown default:
                    try service.unregister()
                }
            }
            settings.launchAtLoginEnabled = enabled
        } catch {
            bannerMessage = "开机自启动设置失败：\(error.localizedDescription)"
        }
    }

    func clearHistory() {
        results = []
        Task { await historyStore.clear() }
        refreshStatusItem()
    }

    func saveXlogProfile(_ profile: XlogProfile, privateKeyHex: String) throws {
        let hasPrivateKey = privateKeyHex.contains { !$0.isWhitespace }
        let isExisting = settings.xlogProfiles.contains { $0.id == profile.id }
        guard hasPrivateKey || isExisting else {
            throw DecodeError.invalidCredentials("新增 Xlog 方案必须填写 64 位 Hex 私钥")
        }
        if hasPrivateKey {
            let credentials = try XlogCredentials(privateKeyHex: privateKeyHex)
            try xlogKeychain.save(credentials.privateKey, account: profile.id.uuidString)
        }
        settings.upsert(profile: profile)
    }

    func xlogPrivateKeyHex(for profile: XlogProfile) throws -> String {
        let key = try xlogKeychain.read(account: profile.id.uuidString)
        return key.map { String(format: "%02x", $0) }.joined()
    }

    func removeXlogProfile(_ profile: XlogProfile) {
        xlogKeychain.remove(account: profile.id.uuidString)
        settings.remove(profile: profile)
    }

    func saveLoganProfile(_ profile: LoganProfile, key: String, iv: String) throws {
        let isExisting = settings.loganProfiles.contains { $0.id == profile.id }
        let hasKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasIV = !iv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isExisting || (hasKey && hasIV) else {
            throw DecodeError.invalidCredentials("新增 Logan 方案必须填写至少 16 字节的 AES Key 和 IV")
        }

        let keyData = hasKey
            ? Data(key.utf8)
            : try loganKeychain.read(account: "\(profile.id.uuidString).key")
        let ivData = hasIV
            ? Data(iv.utf8)
            : try loganKeychain.read(account: "\(profile.id.uuidString).iv")
        _ = try LoganCredentials(key: keyData, iv: ivData)
        try loganKeychain.save(keyData, account: "\(profile.id.uuidString).key")
        try loganKeychain.save(ivData, account: "\(profile.id.uuidString).iv")
        settings.upsert(profile: profile)
    }

    func loganKey(for profile: LoganProfile) throws -> String {
        try loganSecret(for: profile, suffix: "key")
    }

    func loganIV(for profile: LoganProfile) throws -> String {
        try loganSecret(for: profile, suffix: "iv")
    }

    func removeLoganProfile(_ profile: LoganProfile) {
        loganKeychain.remove(account: "\(profile.id.uuidString).key")
        loganKeychain.remove(account: "\(profile.id.uuidString).iv")
        settings.remove(profile: profile)
    }

    func showMainWindow() {
        if let mainWindowPresenter {
            mainWindowPresenter()
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first { window.makeKeyAndOrderFront(nil) }
    }

    private func prepareToProcess(_ url: URL, origin: DecodeOrigin) {
        if folderAccess.authorizedDirectory(containing: url) != nil {
            process(url, origin: origin)
            return
        }

        let sourcePath = url.standardizedFileURL.path
        guard !pendingFolderAccessRequests.contains(where: {
            $0.0.standardizedFileURL.path == sourcePath
        }) else { return }
        pendingFolderAccessRequests.append((url, origin))
        requestNextFolderAuthorization()
    }

    private func requestNextFolderAuthorization() {
        guard !folderAuthorizationInProgress else { return }

        var authorizedRequests: [(URL, DecodeOrigin)] = []
        var unauthorizedRequests: [(URL, DecodeOrigin)] = []
        for request in pendingFolderAccessRequests {
            if folderAccess.authorizedDirectory(containing: request.0) != nil {
                authorizedRequests.append(request)
            } else {
                unauthorizedRequests.append(request)
            }
        }
        pendingFolderAccessRequests = unauthorizedRequests
        authorizedRequests.forEach { process($0.0, origin: $0.1) }

        guard let request = pendingFolderAccessRequests.first else { return }
        let requiredDirectory = request.0.deletingLastPathComponent().standardizedFileURL
        folderAuthorizationInProgress = true

        let panel = NSOpenPanel()
        panel.title = "授权日志所在文件夹"
        if settings.logFormat(for: request.0) == .zip {
            panel.message = "XDecode 需要访问“\(requiredDirectory.lastPathComponent)”以生成 ZIP 批量解密目录；源 ZIP 会保留。"
        } else {
            panel.message = "XDecode 需要访问“\(requiredDirectory.lastPathComponent)”以生成解密结果，并在成功后删除源文件。"
        }
        panel.prompt = "授权文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = requiredDirectory.deletingLastPathComponent()
        panel.nameFieldStringValue = requiredDirectory.lastPathComponent

        if panel.runModal() == .OK, let selectedDirectory = panel.url {
            if FolderAccessStore.contains(fileURL: request.0, directoryURL: selectedDirectory) {
                do {
                    try folderAccess.remember(selectedDirectory)
                } catch {
                    discardRequests(in: requiredDirectory)
                    bannerMessage = "无法保存文件夹授权：\(error.localizedDescription)"
                }
            } else {
                discardRequests(in: requiredDirectory)
                bannerMessage = "请选择包含该日志的文件夹"
            }
        } else {
            discardRequests(in: requiredDirectory)
            bannerMessage = "未授予“\(requiredDirectory.lastPathComponent)”访问权限，日志未处理"
        }

        folderAuthorizationInProgress = false
        requestNextFolderAuthorization()
    }

    private func discardRequests(in directoryURL: URL) {
        pendingFolderAccessRequests.removeAll {
            $0.0.deletingLastPathComponent().standardizedFileURL == directoryURL
        }
    }

    private func process(_ url: URL, origin: DecodeOrigin) {
        guard let directoryAccess = folderAccess.beginAccess(to: url) else {
            bannerMessage = "无法访问日志所在文件夹，请重新添加该日志并授权文件夹"
            return
        }
        let sourcePath = url.standardizedFileURL.path
        guard activeSourcePaths.insert(sourcePath).inserted else {
            directoryAccess.stop()
            return
        }

        let scoped = url.startAccessingSecurityScopedResource()
        activeTaskCount += 1
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                directoryAccess.stop()
                activeSourcePaths.remove(sourcePath)
                activeTaskCount -= 1
            }
            do {
                guard let format = settings.logFormat(for: url) else {
                    throw DecodeError.unsupportedFormat(url.lastPathComponent)
                }
                let request = try DecodeRequest(sourceURL: url, format: format, origin: origin)
                let result: DecodeResult
                if request.format == .zip {
                    result = await zipCoordinator.decode(request)
                } else {
                    result = await coordinator.decode(request)
                }
                guard result.state != .skipped else { return }
                results.insert(result, at: 0)
                await historyStore.append(result)
                if settings.notificationsEnabled { notifications.send(result) }
                refreshStatusItem()
            } catch {
                bannerMessage = error.localizedDescription
            }
        }
    }

    private func xlogCredentials(for url: URL) -> [XlogCredentials] {
        settings.xlogProfiles
            .filter { $0.matches(url) }
            .compactMap { profile in
                guard let key = try? xlogKeychain.read(account: profile.id.uuidString) else { return nil }
                return try? XlogCredentials(privateKey: key)
            }
    }

    private func isSupportedInput(_ url: URL) -> Bool {
        settings.logFormat(for: url) != nil
    }

    private func loganCredentials(for url: URL) throws -> [LoganCredentials] {
        settings.loganProfiles
            .filter { $0.matches(url) }
            .compactMap { profile -> LoganCredentials? in
                guard let key = try? loganKeychain.read(account: "\(profile.id.uuidString).key"),
                      let iv = try? loganKeychain.read(account: "\(profile.id.uuidString).iv")
                else { return nil }
                return try? LoganCredentials(key: key, iv: iv)
            }
    }

    private func loganSecret(for profile: LoganProfile, suffix: String) throws -> String {
        let data = try loganKeychain.read(account: "\(profile.id.uuidString).\(suffix)")
        guard let value = String(data: data, encoding: .utf8) else {
            throw DecodeError.invalidCredentials("钥匙串中的 Logan 密钥不是有效 UTF-8 文本")
        }
        return value
    }

    private func enableAutomaticMonitoring() {
        settings.automaticEnabled = true
        startMonitoring()
    }

    private func startMonitoring() {
        let folders = settings.monitoredFolderURLs
        guard !folders.isEmpty else { return }
        do { try monitor.start(folderURLs: folders) } catch { bannerMessage = "无法监控文件夹：\(error.localizedDescription)" }
    }

    private func refreshStatusItem() {
        statusItem.setEnabled(settings.menuBarEnabled)
        statusItem.update(results: results)
    }
}
