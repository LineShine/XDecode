import Foundation
import Testing
@testable import XDecodeApp

@Suite("Automatic decode suppression", .serialized)
struct AutomaticDecodeSuppressionStoreTests {
    @Test("ZIP output registrations survive reload and are consumed exactly once")
    func persistsAndConsumesRegistrations() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = base.appendingPathComponent(".xdecode-zip-batch.tmp", isDirectory: true)
        let destination = base.appendingPathComponent("123_456", isDirectory: true)
        let registryURL = base.appendingPathComponent("registry/suppressions.json")
        try fileManager.createDirectory(
            at: staging.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("encrypted".utf8).write(to: staging.appendingPathComponent("failed.xlog"))
        try Data("decoded".utf8).write(to: staging.appendingPathComponent("nested/success.log"))
        defer { try? fileManager.removeItem(at: base) }

        let writer = AutomaticDecodeSuppressionStore(fileURL: registryURL)
        try await writer.preparePublication(
            stagingDirectory: staging,
            destinationDirectory: destination
        )
        try fileManager.moveItem(at: staging, to: destination)

        let restored = AutomaticDecodeSuppressionStore(fileURL: registryURL)
        let failedLog = destination.appendingPathComponent("failed.xlog")
        let decodedLog = destination.appendingPathComponent("nested/success.log")
        let firstConsumption = await restored.consumeIfRegistered(failedLog)
        let repeatedConsumption = await restored.consumeIfRegistered(failedLog)
        let decodedConsumption = await restored.consumeIfRegistered(decodedLog)

        #expect(firstConsumption)
        #expect(!repeatedConsumption)
        #expect(decodedConsumption)

        let copiedLog = base.appendingPathComponent("copied.xlog")
        try fileManager.copyItem(at: failedLog, to: copiedLog)
        let copiedConsumption = await restored.consumeIfRegistered(copiedLog)
        #expect(!copiedConsumption)
    }

    @Test("A new file at a registered path is not suppressed when its identity changed")
    func rejectsReplacedFile() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = base.appendingPathComponent(".xdecode-zip-batch.tmp", isDirectory: true)
        let destination = base.appendingPathComponent("output", isDirectory: true)
        let registryURL = base.appendingPathComponent("registry.json")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("archive value".utf8).write(to: staging.appendingPathComponent("failed.mx"))
        defer { try? fileManager.removeItem(at: base) }

        let store = AutomaticDecodeSuppressionStore(fileURL: registryURL)
        try await store.preparePublication(
            stagingDirectory: staging,
            destinationDirectory: destination
        )
        try fileManager.moveItem(at: staging, to: destination)

        let output = destination.appendingPathComponent("failed.mx")
        try fileManager.removeItem(at: output)
        try Data("new download".utf8).write(to: output)
        let suppressed = await store.consumeIfRegistered(output)
        #expect(!suppressed)
    }
}
