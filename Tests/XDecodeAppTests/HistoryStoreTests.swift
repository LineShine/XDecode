import Foundation
import Testing
import XDecodeCore
@testable import XDecodeApp

@Suite("History store")
struct HistoryStoreTests {
    @Test("Memory keeps 30 records while persistence keeps 200 records")
    func capsAndBatchesPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(
            fileURL: fileURL,
            persistenceDelay: .seconds(60),
            maximumPersistenceDelay: .seconds(60)
        )
        let baseDate = Date().addingTimeInterval(-205)
        for index in 0..<205 {
            await store.append(try makeResult(index: index, baseDate: baseDate))
        }

        let inMemoryValues = await store.load()
        #expect(inMemoryValues.count == 30)
        #expect(inMemoryValues.first?.request.sourceURL.lastPathComponent == "204.mx")
        #expect(inMemoryValues.last?.request.sourceURL.lastPathComponent == "175.mx")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let persistedData = try Data(contentsOf: fileURL)
        let persistedValues = try JSONDecoder().decode([DecodeResult].self, from: persistedData)
        #expect(persistedValues.count == 200)
        #expect(persistedValues.last?.request.sourceURL.lastPathComponent == "5.mx")

        let restored = HistoryStore(
            fileURL: fileURL,
            persistenceDelay: .seconds(60),
            maximumPersistenceDelay: .seconds(60)
        )
        let values = await restored.load()
        #expect(values.count == 30)
        #expect(values.first?.request.sourceURL.lastPathComponent == "204.mx")
        #expect(values.last?.request.sourceURL.lastPathComponent == "175.mx")
    }

    @Test("Continuous updates are persisted by the maximum delay")
    func enforcesMaximumPersistenceDelay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(
            fileURL: fileURL,
            persistenceDelay: .seconds(1),
            maximumPersistenceDelay: .milliseconds(50)
        )
        await store.append(try makeResult(index: 1, baseDate: Date()))
        try await Task.sleep(for: .milliseconds(150))

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Persisted history excludes records older than thirty days")
    func removesExpiredPersistedRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldDate = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        let values = [
            try makeResult(index: 1, baseDate: oldDate),
            try makeResult(index: 2, baseDate: Date()),
        ]
        try JSONEncoder().encode(values).write(to: fileURL)

        let store = HistoryStore(
            fileURL: fileURL,
            persistenceDelay: .seconds(60),
            maximumPersistenceDelay: .seconds(60)
        )
        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.request.sourceURL.lastPathComponent == "2.mx")

        await store.flush()
        let persistedData = try Data(contentsOf: fileURL)
        let persisted = try JSONDecoder().decode([DecodeResult].self, from: persistedData)
        #expect(persisted.count == 1)
    }

    private func makeResult(index: Int, baseDate: Date) throws -> DecodeResult {
        let date = baseDate.addingTimeInterval(TimeInterval(index))
        let request = try DecodeRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/\(index).mx"),
            format: .mx,
            origin: .automatic,
            requestedAt: date
        )
        return DecodeResult(
            request: request,
            state: .completed,
            outputURL: URL(fileURLWithPath: "/tmp/\(index).log"),
            message: "完成",
            sourceDeleted: true,
            finishedAt: date
        )
    }
}
