import Foundation

actor FileStabilityGate {
    struct Snapshot: Equatable {
        let size: Int64
        let modified: Date
    }

    func waitUntilStable(_ url: URL, checks: Int = 3) async -> Bool {
        var previous: Snapshot?
        var stableCount = 0

        while !Task.isCancelled {
            guard let snapshot = snapshot(url) else { return false }
            if snapshot == previous {
                stableCount += 1
                if stableCount >= checks { return true }
            } else {
                stableCount = 0
                previous = snapshot
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
        }
        return false
    }

    private func snapshot(_ url: URL) -> Snapshot? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return Snapshot(size: Int64(size), modified: modified)
    }
}
