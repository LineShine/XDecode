import Foundation

actor FileStabilityGate {
    static let requiredStableCheckCount = 2
    static let maximumWait: Duration = .seconds(60)

    struct Snapshot: Equatable {
        let size: Int64
        let modified: Date
    }

    private var pendingPaths = Set<String>()

    func waitUntilStable(
        _ url: URL,
        checks: Int = requiredStableCheckCount,
        interval: Duration = .seconds(1),
        timeout: Duration = maximumWait
    ) async -> Bool {
        let path = url.standardizedFileURL.path
        guard pendingPaths.insert(path).inserted else { return false }
        defer { pendingPaths.remove(path) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previous: Snapshot?
        var stableCount = 0

        while !Task.isCancelled {
            guard clock.now < deadline else { return false }
            guard let snapshot = snapshot(url) else { return false }
            if snapshot == previous {
                stableCount += 1
                if stableCount >= checks { return true }
            } else {
                stableCount = 0
                previous = snapshot
            }
            do {
                let nextCheck = min(clock.now.advanced(by: interval), deadline)
                try await clock.sleep(until: nextCheck)
            } catch {
                return false
            }
        }
        return false
    }

    private func snapshot(_ url: URL) -> Snapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Snapshot(size: size.int64Value, modified: modified)
    }
}
