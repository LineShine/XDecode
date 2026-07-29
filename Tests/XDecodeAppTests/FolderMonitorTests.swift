import Foundation
import Testing
@testable import XDecodeApp

@Suite("Folder monitor", .serialized)
@MainActor
struct FolderMonitorTests {
    @Test("FSEvents recursively delivers regular files for app-side filtering")
    func deliversFileEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let monitor = FolderMonitor()
        var continuation: AsyncStream<URL>.Continuation?
        let events = AsyncStream<URL> { continuation = $0 }
        monitor.onNewFile = { continuation?.yield($0) }
        try monitor.start(folderURL: directory)
        defer {
            monitor.stop()
            continuation?.finish()
            try? FileManager.default.removeItem(at: directory)
        }

        let topLevelFiles = [
            "first.xlog",
            "second.mx",
            "2026-07-27",
            "123_456.zip",
            "readme.txt",
        ].map {
            directory.appendingPathComponent($0)
        }
        let writer = Task.detached(priority: .utility) {
            try await Task.sleep(for: .milliseconds(250))
            let generatedDirectory = directory.appendingPathComponent("123_456", isDirectory: true)
            try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
            let nestedLog = generatedDirectory.appendingPathComponent("failed.xlog")
            try Data("fixture".utf8).write(to: nestedLog)
            for url in topLevelFiles {
                try Data("fixture".utf8).write(to: url)
            }
        }
        let expected = topLevelFiles + [directory.appendingPathComponent("123_456/failed.xlog")]

        let received = await firstEvents(from: events, count: expected.count)
        try await writer.value

        #expect(Set(received.map(\.standardizedFileURL)) == Set(expected.map(\.standardizedFileURL)))
    }

    @Test("One FSEvents stream monitors multiple folders and their descendants")
    func monitorsMultipleFolders() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let monitor = FolderMonitor()
        var continuation: AsyncStream<URL>.Continuation?
        let events = AsyncStream<URL> { continuation = $0 }
        monitor.onNewFile = { continuation?.yield($0) }
        try monitor.start(folderURLs: [first, second])
        defer {
            monitor.stop()
            continuation?.finish()
            try? FileManager.default.removeItem(at: base)
        }

        let expected = [
            first.appendingPathComponent("nested/first.xlog"),
            second.appendingPathComponent("deep/logs/2026-07-27"),
        ]
        let writer = Task.detached(priority: .utility) {
            try await Task.sleep(for: .milliseconds(250))
            for url in expected {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("fixture".utf8).write(to: url)
            }
        }

        let received = await firstEvents(from: events, count: expected.count)
        try await writer.value
        #expect(Set(received.map(\.standardizedFileURL)) == Set(expected.map(\.standardizedFileURL)))
    }

    @Test("Changing a file that existed before monitoring does not report it as new")
    func ignoresChangesToExistingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("existing.xlog")
        let newlyCreated = directory.appendingPathComponent("new.mx")
        try Data("before".utf8).write(to: existing)

        let monitor = FolderMonitor()
        var continuation: AsyncStream<URL>.Continuation?
        let events = AsyncStream<URL> { continuation = $0 }
        monitor.onNewFile = { continuation?.yield($0) }
        try monitor.start(folderURL: directory)
        defer {
            monitor.stop()
            continuation?.finish()
            try? FileManager.default.removeItem(at: directory)
        }

        let writer = Task.detached(priority: .utility) {
            try await Task.sleep(for: .milliseconds(250))
            try Data("after".utf8).write(to: existing)
            try await Task.sleep(for: .milliseconds(250))
            try Data("new".utf8).write(to: newlyCreated)
        }

        let received = await firstEvents(from: events, count: 1)
        try await writer.value
        #expect(received.map(\.standardizedFileURL) == [newlyCreated.standardizedFileURL])
    }

    private func firstEvents(from events: AsyncStream<URL>, count: Int) async -> [URL] {
        await withTaskGroup(of: [URL].self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                var received: [URL] = []
                while received.count < count, let event = await iterator.next() {
                    received.append(event)
                }
                return received
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return []
            }

            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}
