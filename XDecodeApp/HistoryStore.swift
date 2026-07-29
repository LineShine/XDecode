import Foundation
import XDecodeCore

actor HistoryStore {
    static let maximumInMemoryCount = 30
    static let maximumPersistedCount = 200

    private let fileManager: FileManager
    private let fileURL: URL
    private let retention: TimeInterval
    private let maximumInMemoryCount: Int
    private let maximumPersistedCount: Int
    private let persistenceDelay: Duration
    private let maximumPersistenceDelay: Duration
    private var persistedValues: [DecodeResult]?
    private var debouncedPersistenceTask: Task<Void, Never>?
    private var maximumDelayPersistenceTask: Task<Void, Never>?

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        maximumInMemoryCount: Int = HistoryStore.maximumInMemoryCount,
        maximumPersistedCount: Int = HistoryStore.maximumPersistedCount,
        persistenceDelay: Duration = .seconds(1),
        maximumPersistenceDelay: Duration = .seconds(5)
    ) {
        self.fileManager = fileManager
        self.retention = retention
        self.maximumInMemoryCount = maximumInMemoryCount
        self.maximumPersistedCount = maximumPersistedCount
        self.persistenceDelay = persistenceDelay
        self.maximumPersistenceDelay = maximumPersistenceDelay
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("XDecode", isDirectory: true)
            try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("history.json")
        }
    }

    func load() -> [DecodeResult] {
        Array(loadPersistedValues().prefix(maximumInMemoryCount))
    }

    func append(_ result: DecodeResult) {
        guard result.state != .skipped else { return }
        var values = loadPersistedValues()
        values.removeAll { $0.id == result.id }
        values.insert(result, at: 0)
        persistedValues = retainedValues(from: values)
        schedulePersistence()
    }

    func flush() {
        persistValues()
    }

    func clear() {
        cancelPersistenceTasks()
        persistedValues = []
        try? fileManager.removeItem(at: fileURL)
    }

    private func loadPersistedValues() -> [DecodeResult] {
        if let persistedValues {
            let retained = retainedValues(from: persistedValues)
            if retained.count != persistedValues.count {
                self.persistedValues = retained
                schedulePersistence()
            }
            return retained
        }
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([DecodeResult].self, from: data) else {
            persistedValues = []
            return []
        }
        let retained = retainedValues(from: values)
        persistedValues = retained
        if retained.count != values.count {
            schedulePersistence()
        }
        return retained
    }

    private func retainedValues(from values: [DecodeResult]) -> [DecodeResult] {
        let cutoff = Date().addingTimeInterval(-retention)
        return Array(values
            .filter { $0.state != .skipped && $0.finishedAt >= cutoff }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(maximumPersistedCount))
    }

    private func schedulePersistence() {
        debouncedPersistenceTask?.cancel()
        let debounceDelay = persistenceDelay
        debouncedPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounceDelay)
            } catch {
                return
            }
            await self?.persistValues()
        }

        guard maximumDelayPersistenceTask == nil else { return }
        let maximumDelay = maximumPersistenceDelay
        maximumDelayPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: maximumDelay)
            } catch {
                return
            }
            await self?.persistValues()
        }
    }

    private func persistValues() {
        cancelPersistenceTasks()
        guard let persistedValues,
              let data = try? JSONEncoder().encode(persistedValues) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private func cancelPersistenceTasks() {
        debouncedPersistenceTask?.cancel()
        debouncedPersistenceTask = nil
        maximumDelayPersistenceTask?.cancel()
        maximumDelayPersistenceTask = nil
    }
}
