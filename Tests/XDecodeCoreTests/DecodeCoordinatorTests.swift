import Foundation
import Testing
@testable import XDecodeCore

@Suite("Decode coordinator")
struct DecodeCoordinatorTests {
    @Test("Output names replace the source extension")
    func outputNames() {
        let source = URL(fileURLWithPath: "/tmp/archive.part.xlog")
        #expect(DecodeCoordinator.outputURL(for: source).lastPathComponent == "archive.part.log")
        #expect(DecodeCoordinator.outputURL(for: source, index: 1).lastPathComponent == "archive.part-1.log")
    }

    @Test("Successful decode writes a unique log then permanently deletes the source")
    func successDeletesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("sample.mx")
        let existing = directory.appendingPathComponent("sample.log")
        try Data("encrypted".utf8).write(to: source)
        try Data("older".utf8).write(to: existing)

        let coordinator = DecodeCoordinator { _ in StubDecoder(output: Data("decoded".utf8)) }
        let request = try DecodeRequest(sourceURL: source, origin: .filePicker)
        let result = await coordinator.decode(request)

        #expect(result.state == .completed)
        #expect(result.outputURL?.lastPathComponent == "sample-1.log")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: result.outputURL!, encoding: .utf8) == "decoded")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "older")
    }

    @Test("Partial decode is an error, creates no output, and preserves the source")
    func partialDecodeFailsWithoutOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("partial.xlog")
        let expectedOutput = directory.appendingPathComponent("partial.log")
        try Data("fixture".utf8).write(to: source)
        let decoded = DecodedLog.partial(
            Data("successful frame\n".utf8),
            diagnostic: "Xlog 部分解密：成功 1 帧，失败 1 帧"
        )
        let coordinator = DecodeCoordinator { _ in ResultDecoder(result: decoded) }
        let result = await coordinator.decode(try DecodeRequest(sourceURL: source, origin: .dragAndDrop))

        #expect(result.state == .failed)
        #expect(result.sourceDeleted == false)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(result.outputURL == nil)
        #expect(!FileManager.default.fileExists(atPath: expectedOutput.path))
        #expect(result.message.contains("成功 1 帧，失败 1 帧"))
        #expect(result.message.contains("未生成 .log"))
    }

    @Test("Failed decode preserves the source and creates no output")
    func failurePreservesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("broken.xlog")
        try Data("broken".utf8).write(to: source)

        let coordinator = DecodeCoordinator { _ in ThrowingDecoder() }
        let result = await coordinator.decode(try DecodeRequest(sourceURL: source, origin: .automatic))

        #expect(result.state == .failed)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(result.outputURL == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.log").path))
    }

    @Test("Malformed Logan preserves the source and creates no output")
    func malformedLoganPreservesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("2026-07-28")
        let expectedOutput = directory.appendingPathComponent("2026-07-28.log")
        try Data([0x01, 0x00, 0x00, 0x00, 0x10, 0xAA]).write(to: source)
        let credentials = try LoganCredentials(
            key: "0123456789067890",
            iv: "0123456789067890"
        )
        let coordinator = DecodeCoordinator { _ in LoganDecoder(credentials: credentials) }
        let request = try DecodeRequest(sourceURL: source, format: .logan, origin: .automatic)

        let result = await coordinator.decode(request)

        #expect(result.state == .failed)
        #expect(result.outputURL == nil)
        #expect(result.sourceDeleted == false)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: expectedOutput.path))
    }

    @Test("Concurrent coordinators reserve different output names")
    func concurrentOutputReservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let xlogSource = directory.appendingPathComponent("shared.xlog")
        let mxSource = directory.appendingPathComponent("shared.mx")
        try Data("xlog".utf8).write(to: xlogSource)
        try Data("mx".utf8).write(to: mxSource)

        let first = DecodeCoordinator { _ in StubDecoder(output: Data("first".utf8)) }
        let second = DecodeCoordinator { _ in StubDecoder(output: Data("second".utf8)) }
        let firstRequest = try DecodeRequest(sourceURL: xlogSource, origin: .filePicker)
        let secondRequest = try DecodeRequest(sourceURL: mxSource, origin: .automatic)

        async let firstResult = first.decode(firstRequest)
        async let secondResult = second.decode(secondRequest)
        let results = await [firstResult, secondResult]
        let names = Set(results.compactMap { $0.outputURL?.lastPathComponent })

        #expect(results.allSatisfy { $0.state == .completed })
        #expect(names == ["shared.log", "shared-1.log"])
        #expect(!FileManager.default.fileExists(atPath: xlogSource.path))
        #expect(!FileManager.default.fileExists(atPath: mxSource.path))
    }
}

private struct StubDecoder: LogDecoder {
    let format = LogFormat.mx
    let output: Data
    func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog { .complete(output) }
}

private struct ResultDecoder: LogDecoder {
    let format = LogFormat.xlog
    let result: DecodedLog
    func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog { result }
}

private struct ThrowingDecoder: LogDecoder {
    let format = LogFormat.xlog
    func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog {
        throw DecodeError.malformed("fixture")
    }
}
