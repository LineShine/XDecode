import Foundation
import Testing
@testable import XDecodeApp

@Suite("File stability gate")
struct FileStabilityGateTests {
    @Test("Default stability policy uses two checks and a sixty-second timeout")
    func defaultPolicy() {
        #expect(FileStabilityGate.requiredStableCheckCount == 2)
        #expect(FileStabilityGate.maximumWait == .seconds(60))
    }

    @Test("A stable file passes after consecutive snapshots")
    func stableFilePasses() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("stable".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let gate = FileStabilityGate()
        let isStable = await gate.waitUntilStable(
            url,
            checks: 2,
            interval: .milliseconds(10),
            timeout: .milliseconds(100)
        )

        #expect(isStable)
    }

    @Test("Concurrent checks for the same path are deduplicated")
    func duplicatePathIsRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("stable".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let gate = FileStabilityGate()
        async let first = gate.waitUntilStable(
            url,
            checks: 3,
            interval: .milliseconds(20),
            timeout: .milliseconds(200)
        )
        try await Task.sleep(for: .milliseconds(5))
        let duplicate = await gate.waitUntilStable(
            url,
            checks: 3,
            interval: .milliseconds(20),
            timeout: .milliseconds(200)
        )

        #expect(!duplicate)
        #expect(await first)
    }

    @Test("Continuously changing files stop at the timeout")
    func changingFileTimesOut() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = Task.detached(priority: .utility) {
            for value in 0..<20 {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([UInt8(value)]))
                try handle.close()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let gate = FileStabilityGate()
        let isStable = await gate.waitUntilStable(
            url,
            checks: 3,
            interval: .milliseconds(20),
            timeout: .milliseconds(100)
        )
        try await writer.value

        #expect(!isStable)
    }
}
