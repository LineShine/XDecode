import CoreServices
import Foundation

@MainActor
final class FolderMonitor {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var folderURLs = [URL]()
    private var accessedFolderURLs = [URL]()
    private var knownFiles = Set<String>()
    private var scanTask: Task<Void, Never>?
    var onNewFile: ((URL) -> Void)?

    deinit {
        scanTask?.cancel()
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
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
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
        scanTask?.cancel()
        scanTask = nil
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

    private func scheduleScan() {
        scanTask?.cancel()
        let folders = folderURLs
        guard !folders.isEmpty else { return }

        scanTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            let current = await Task.detached(priority: .utility) {
                Self.regularFiles(in: folders)
            }.value
            guard !Task.isCancelled, let self else { return }

            let added = current.subtracting(knownFiles)
            knownFiles = current
            for path in added.sorted() {
                onNewFile?(URL(fileURLWithPath: path))
            }
        }
    }

    private nonisolated static let eventCallback: FSEventStreamCallback = {
        _, info, _, _, _, _ in
        guard let info else { return }
        let monitor = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
        Task { @MainActor in
            monitor.scheduleScan()
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
