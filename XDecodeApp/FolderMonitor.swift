import CoreServices
import Foundation

@MainActor
final class FolderMonitor {
    private struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        var requiresRecoveryScan: Bool {
            let recoveryFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
            )
            return flags & recoveryFlags != 0
        }

        var createdOrRenamed: Bool {
            let creationFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagItemCloned
            )
            return flags & creationFlags != 0
        }

        var removed: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
        }
    }

    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var folderURLs = [URL]()
    private var accessedFolderURLs = [URL]()
    private var knownFiles = Set<String>()
    private var recoveryScanTask: Task<Void, Never>?
    private var directoryScanTask: Task<Void, Never>?
    private var pendingDirectoryScanURLs = Set<URL>()
    var onNewFile: ((URL) -> Void)?

    deinit {
        recoveryScanTask?.cancel()
        directoryScanTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        for url in accessedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func start(folderURL: URL) throws {
        try start(folderURLs: [folderURL])
    }

    func start(folderURLs: [URL]) throws {
        stop()

        let uniqueFolders = Self.uniqueFolders(folderURLs)
        guard !uniqueFolders.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        for url in uniqueFolders {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            if url.startAccessingSecurityScopedResource() {
                accessedFolderURLs.append(url)
            }
        }

        let sinceEventID = FSEventsGetCurrentEventId()
        self.folderURLs = uniqueFolders
        knownFiles = Self.regularFiles(in: uniqueFolders)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let createdStream = FSEventStreamCreate(
            nil,
            Self.eventCallback,
            &context,
            uniqueFolders.map(\.path) as CFArray,
            sinceEventID,
            0.15,
            flags
        ) else {
            stop()
            throw CocoaError(.fileReadUnknown)
        }

        FSEventStreamSetDispatchQueue(createdStream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            stop()
            throw CocoaError(.fileReadUnknown)
        }
        stream = createdStream
    }

    func stop() {
        recoveryScanTask?.cancel()
        recoveryScanTask = nil
        directoryScanTask?.cancel()
        directoryScanTask = nil
        pendingDirectoryScanURLs.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        knownFiles.removeAll()
        folderURLs.removeAll()
        for url in accessedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedFolderURLs.removeAll()
    }

    private func handle(_ events: [Event]) {
        guard !folderURLs.isEmpty else { return }
        if events.contains(where: \.requiresRecoveryScan) {
            scheduleRecoveryScan()
            return
        }

        var newFiles = [URL]()
        var directoriesToScan = Set<URL>()
        for event in events {
            let url = URL(fileURLWithPath: event.path).standardizedFileURL
            guard isInsideMonitoredFolder(url) else { continue }
            guard !isHidden(url) else { continue }

            if event.removed {
                removeKnownPaths(atOrBelow: url.path)
                if !event.createdOrRenamed { continue }
            }

            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
            ]) else {
                removeKnownPaths(atOrBelow: url.path)
                continue
            }

            if values.isRegularFile == true {
                if knownFiles.insert(url.path).inserted {
                    newFiles.append(url)
                }
            } else if values.isDirectory == true, event.createdOrRenamed {
                directoriesToScan.insert(url)
            }
        }

        emit(newFiles)
        if !directoriesToScan.isEmpty {
            scheduleDirectoryScan(directoriesToScan)
        }
    }

    private func scheduleRecoveryScan() {
        guard recoveryScanTask == nil else { return }
        let folders = folderURLs
        guard !folders.isEmpty else { return }

        recoveryScanTask = Task { [weak self] in
            let current = await Task.detached(priority: .utility) {
                Self.regularFiles(in: folders)
            }.value
            guard !Task.isCancelled, let self else { return }

            let added = current.subtracting(knownFiles)
            knownFiles = current
            recoveryScanTask = nil
            emit(added.sorted().map(URL.init(fileURLWithPath:)))
        }
    }

    private func scheduleDirectoryScan(_ directories: Set<URL>) {
        pendingDirectoryScanURLs.formUnion(directories)
        guard directoryScanTask == nil else { return }

        directoryScanTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self else { return }
            let directories = Array(pendingDirectoryScanURLs)
            pendingDirectoryScanURLs.removeAll()
            let discovered = await Task.detached(priority: .utility) {
                Self.regularFiles(in: directories)
            }.value
            guard !Task.isCancelled else { return }

            let added = discovered.subtracting(knownFiles)
            knownFiles.formUnion(discovered)
            directoryScanTask = nil
            emit(added.sorted().map(URL.init(fileURLWithPath:)))

            if !pendingDirectoryScanURLs.isEmpty {
                scheduleDirectoryScan([])
            }
        }
    }

    private func emit(_ urls: [URL]) {
        for url in urls {
            onNewFile?(url)
        }
    }

    private func removeKnownPaths(atOrBelow path: String) {
        let descendantPrefix = path.hasSuffix("/") ? path : path + "/"
        knownFiles = Set(knownFiles.filter {
            $0 != path && !$0.hasPrefix(descendantPrefix)
        })
    }

    private func isInsideMonitoredFolder(_ url: URL) -> Bool {
        folderURLs.contains { folder in
            let folderPath = folder.standardizedFileURL.path
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            return url.path == folderPath || url.path.hasPrefix(prefix)
        }
    }

    private func isHidden(_ url: URL) -> Bool {
        guard let folder = folderURLs.first(where: { folder in
            let folderPath = folder.standardizedFileURL.path
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            return url.path == folderPath || url.path.hasPrefix(prefix)
        }) else { return true }
        let relativeComponents = url.pathComponents.dropFirst(folder.pathComponents.count)
        return relativeComponents.contains { $0.hasPrefix(".") }
    }

    private nonisolated static let eventCallback: FSEventStreamCallback = {
        _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info, eventCount > 0 else { return }
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var events = [Event]()
        events.reserveCapacity(eventCount)
        for index in 0..<eventCount {
            guard let path = paths[index] else { continue }
            events.append(Event(
                path: String(cString: path),
                flags: eventFlags[index]
            ))
        }
        guard !events.isEmpty else { return }
        let monitor = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
        Task { @MainActor in
            monitor.handle(events)
        }
    }

    private nonisolated static func uniqueFolders(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(normalized.path).inserted ? url.standardizedFileURL : nil
        }
    }

    private nonisolated static func regularFiles(in folders: [URL]) -> Set<String> {
        var files = Set<String>()
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                files.insert(url.standardizedFileURL.path)
            }
        }
        return files
    }
}
