import Foundation
import XDecodeCore

actor HistoryStore {
    private let fileURL: URL
    private let retention: TimeInterval = 30 * 24 * 60 * 60

    init(fileManager: FileManager = .default) {
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lingxiang.XDecode")
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("XDecode", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
    }

    func load() -> [DecodeResult] {
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([DecodeResult].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-retention)
        return values.filter { $0.finishedAt >= cutoff }.sorted { $0.finishedAt > $1.finishedAt }
    }

    func append(_ result: DecodeResult) {
        var values = load()
        values.insert(result, at: 0)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
