import Darwin
import Foundation
import XDecodeCore

actor AutomaticDecodeSuppressionStore: ZipOutputPublicationTracking {
    private struct FileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Entry: Codable {
        let destinationPath: String
        let identity: FileIdentity
    }

    private struct Batch: Codable {
        let stagingPath: String
        let destinationRootPath: String
        let createdAt: Date
        var entries: [Entry]
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let retention: TimeInterval
    private var batches: [Batch]

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        retention: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.fileManager = fileManager
        self.retention = retention
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: SharedContainer.identifier
            ) ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("XDecode", isDirectory: true)
            self.fileURL = base.appendingPathComponent("automatic-decode-suppressions.json")
        }

        if let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode([Batch].self, from: data) {
            batches = stored
        } else {
            batches = []
        }
    }

    func preparePublication(stagingDirectory: URL, destinationDirectory: URL) throws {
        _ = removeExpiredEntries()
        let stagingPath = Self.normalizedPath(stagingDirectory)
        let destinationRootPath = Self.normalizedPath(destinationDirectory)
        let entries = try regularFiles(in: stagingDirectory).map { fileURL in
            let relativePath = try relativePath(of: fileURL, in: stagingDirectory)
            let destinationURL = destinationDirectory.appendingPathComponent(relativePath)
            guard let identity = Self.fileIdentity(for: fileURL) else {
                throw CocoaError(.fileReadUnknown)
            }
            return Entry(
                destinationPath: Self.normalizedPath(destinationURL),
                identity: identity
            )
        }

        batches.removeAll { $0.stagingPath == stagingPath }
        batches.append(Batch(
            stagingPath: stagingPath,
            destinationRootPath: destinationRootPath,
            createdAt: Date(),
            entries: entries
        ))
        try persist()
    }

    func cancelPublication(stagingDirectory: URL) {
        let stagingPath = Self.normalizedPath(stagingDirectory)
        batches.removeAll { $0.stagingPath == stagingPath }
        try? persist()
    }

    func consumeIfRegistered(_ url: URL) -> Bool {
        let removedExpiredEntries = removeExpiredEntries()
        let path = Self.normalizedPath(url)
        guard let identity = Self.fileIdentity(for: url) else {
            if removedExpiredEntries { try? persist() }
            return false
        }

        var matched = false
        var changed = false
        for batchIndex in batches.indices.reversed() {
            for entryIndex in batches[batchIndex].entries.indices.reversed()
            where batches[batchIndex].entries[entryIndex].destinationPath == path {
                let entry = batches[batchIndex].entries[entryIndex]
                batches[batchIndex].entries.remove(at: entryIndex)
                changed = true
                if entry.identity == identity {
                    matched = true
                }
            }
            if batches[batchIndex].entries.isEmpty {
                batches.remove(at: batchIndex)
            }
        }

        if changed || removedExpiredEntries { try? persist() }
        return matched
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return enumerator.compactMap { value -> URL? in
            guard let url = value as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }
    }

    private func relativePath(of fileURL: URL, in directory: URL) throws -> String {
        let directoryPath = Self.normalizedPath(directory) + "/"
        let filePath = Self.normalizedPath(fileURL)
        guard filePath.hasPrefix(directoryPath) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return String(filePath.dropFirst(directoryPath.count))
    }

    @discardableResult
    private func removeExpiredEntries(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-retention)
        let previousCount = batches.count
        batches.removeAll { $0.createdAt < cutoff }
        return batches.count != previousCount
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(batches)
        try data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func fileIdentity(for url: URL) -> FileIdentity? {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else { return nil }
        return FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private nonisolated static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
