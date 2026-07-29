import Foundation
import Testing
import ZIPFoundation
@testable import XDecodeCore

@Suite("ZIP batch decoding")
struct ZipDecodeCoordinatorTests {
    @Test("Logs decode into a same-name directory while unrelated entries are preserved")
    func successfulBatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("58321336_51471942.zip")
        try makeArchive(at: source, entries: [
            ("first.xlog", Data("first payload".utf8)),
            ("nested/second.mx", Data("second payload".utf8)),
            ("nested/2026-07-27", Data("logan payload".utf8)),
            ("already-decoded.log", Data("existing log".utf8)),
            ("notes/readme.txt", Data("keep me".utf8)),
            ("__MACOSX/._first.xlog", Data("metadata".utf8)),
        ])

        let coordinator = ZipDecodeCoordinator { request in
            PassthroughDecoder(format: request.format)
        }
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .dragAndDrop)
        )

        let output = try #require(result.outputURL)
        #expect(result.state == .completed)
        #expect(!result.sourceDeleted)
        #expect(output.lastPathComponent == "58321336_51471942")
        #expect(FileManager.default.fileExists(atPath: source.path))
        let outputFileCount = try regularFileCount(in: output)
        #expect(outputFileCount == 5)
        #expect(try contents(of: output.appendingPathComponent("first.log")) == "first payload")
        #expect(try contents(of: output.appendingPathComponent("nested/second.log")) == "second payload")
        #expect(try contents(of: output.appendingPathComponent("nested/2026-07-27.log")) == "logan payload")
        #expect(try contents(of: output.appendingPathComponent("already-decoded.log")) == "existing log")
        #expect(try contents(of: output.appendingPathComponent("notes/readme.txt")) == "keep me")
        #expect(!FileManager.default.fileExists(
            atPath: output.appendingPathComponent("__MACOSX/._first.xlog").path
        ))
    }

    @Test("One incomplete entry produces a partial-success directory with the original failed log")
    func incompleteBatchPreservesFailedLog() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("1_2.zip")
        try makeArchive(at: source, entries: [
            ("first.xlog", Data("first payload".utf8)),
            ("broken.mx", Data("broken payload".utf8)),
            ("readme.txt", Data("keep only on success".utf8)),
        ])

        let coordinator = ZipDecodeCoordinator { request in
            if request.format == .mx {
                return FixedResultDecoder(
                    format: .mx,
                    result: .partial(Data("partial".utf8), diagnostic: "MX 未完整解密")
                )
            }
            return PassthroughDecoder(format: request.format)
        }
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .automatic)
        )

        #expect(result.state == .partiallyCompleted)
        let output = try #require(result.outputURL)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try regularFileCount(in: output) == 3)
        #expect(try contents(of: output.appendingPathComponent("first.log")) == "first payload")
        #expect(try contents(of: output.appendingPathComponent("broken.mx")) == "broken payload")
        #expect(try contents(of: output.appendingPathComponent("readme.txt")) == "keep only on success")
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("broken.log").path))
        #expect(result.message.contains("部分成功"))
    }

    @Test("All decode failures still produce a complete directory of original logs")
    func failedBatchPreservesEveryEntry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("3_4.zip")
        try makeArchive(at: source, entries: [
            ("first.xlog", Data("first encrypted".utf8)),
            ("nested/second.mx", Data("second encrypted".utf8)),
            ("readme.txt", Data("unchanged".utf8)),
        ])
        let coordinator = ZipDecodeCoordinator { request in
            FixedResultDecoder(
                format: request.format,
                result: .partial(Data(), diagnostic: "fixture failure")
            )
        }

        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .automatic)
        )

        let output = try #require(result.outputURL)
        #expect(result.state == .failed)
        #expect(!result.sourceDeleted)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try regularFileCount(in: output) == 3)
        #expect(try contents(of: output.appendingPathComponent("first.xlog")) == "first encrypted")
        #expect(try contents(of: output.appendingPathComponent("nested/second.mx")) == "second encrypted")
        #expect(try contents(of: output.appendingPathComponent("readme.txt")) == "unchanged")
        #expect(result.message.contains("批量解密失败"))
    }

    @Test("Archive without supported logs is skipped before extraction")
    func rejectsArchiveWithoutLogs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("12_34.zip")
        try makeArchive(at: source, entries: [("readme.txt", Data("text".utf8))])

        let coordinator = ZipDecodeCoordinator { request in
            PassthroughDecoder(format: request.format)
        }
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .filePicker)
        )

        #expect(result.state == .skipped)
        #expect(result.outputURL == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("12_34").path))
        #expect(result.message.contains("没有符合当前规则"))
    }

    @Test("ZIP files larger than 500 MB are rejected before opening")
    func rejectsOversizedArchive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("oversized.zip")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: DecodeLimits.maximumInputFileSize + 1)
        try handle.close()

        let coordinator = ZipDecodeCoordinator { request in
            PassthroughDecoder(format: request.format)
        }
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, format: .zip, origin: .automatic)
        )

        #expect(result.state == .failed)
        #expect(result.outputURL == nil)
        #expect(result.message.contains("500 MB"))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("CRC mismatch fails the batch without creating output")
    func rejectsCRCMismatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("90_91.zip")
        let payload = Data("unique-crc-payload-3f8f07".utf8)
        try makeArchive(
            at: source,
            entries: [("damaged.xlog", payload)],
            compressionMethod: .none
        )
        var archiveData = try Data(contentsOf: source)
        let payloadRange = try #require(archiveData.range(of: payload))
        archiveData[payloadRange.lowerBound] ^= 0x01
        try archiveData.write(to: source)

        let coordinator = ZipDecodeCoordinator { request in
            PassthroughDecoder(format: request.format)
        }
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .filePicker)
        )

        #expect(result.state == .failed)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("90_91").path))
        #expect(result.message.contains("CRC 校验失败"))
    }

    @Test("Existing output folders and log entries receive conflict-free names")
    func resolvesDirectoryAndEntryConflicts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingDirectory = directory.appendingPathComponent("7_8", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
        try Data("marker".utf8).write(to: existingDirectory.appendingPathComponent("marker.txt"))

        let source = directory.appendingPathComponent("7_8.zip")
        try makeArchive(at: source, entries: [
            ("foo.log", Data("existing decoded log".utf8)),
            ("foo.xlog", Data("new decoded log".utf8)),
        ])
        let coordinator = ZipDecodeCoordinator { request in
            PassthroughDecoder(format: request.format)
        }
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .filePicker)
        )

        let output = try #require(result.outputURL)
        #expect(output.lastPathComponent == "7_8-1")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try regularFileCount(in: output) == 2)
        #expect(try contents(of: existingDirectory.appendingPathComponent("marker.txt")) == "marker")
        #expect(try contents(of: output.appendingPathComponent("foo.log")) == "existing decoded log")
        #expect(try contents(of: output.appendingPathComponent("foo-1.log")) == "new decoded log")
    }

    @Test("A custom entry resolver can classify an extensionless Logan file")
    func customExtensionlessLoganRule() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("20_21.zip")
        try makeArchive(at: source, entries: [("device-current", Data("logan".utf8))])

        let coordinator = ZipDecodeCoordinator(
            decoderResolver: { request in PassthroughDecoder(format: request.format) },
            entryFormatResolver: { url in
                url.lastPathComponent == "device-current" ? .logan : nil
            }
        )
        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .automatic)
        )

        let output = try #require(result.outputURL)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try contents(of: output.appendingPathComponent("device-current.log")) == "logan")
    }

    @Test("Output publication is registered before the staging directory is renamed")
    func registersBeforePublishing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("30_31.zip")
        try makeArchive(at: source, entries: [("failed.xlog", Data("payload".utf8))])
        let tracker = RecordingPublicationTracker()
        let coordinator = ZipDecodeCoordinator(
            decoderResolver: { request in PassthroughDecoder(format: request.format) },
            publicationTracker: tracker
        )

        let result = await coordinator.decode(
            try DecodeRequest(sourceURL: source, origin: .automatic)
        )
        let preparation = await tracker.preparation
        let output = try #require(result.outputURL)

        #expect(preparation?.stagingExisted == true)
        #expect(preparation?.destinationExisted == false)
        #expect(preparation?.destination == output.standardizedFileURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeArchive(
        at url: URL,
        entries: [(String, Data)],
        compressionMethod: CompressionMethod = .deflate
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: compressionMethod
            ) { position, size in
                let lowerBound = Int(position)
                let upperBound = min(lowerBound + size, data.count)
                return data.subdata(in: lowerBound..<upperBound)
            }
        }
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func regularFileCount(in directory: URL) throws -> Int {
        var count = 0
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                count += try regularFileCount(in: url)
            } else {
                count += 1
            }
        }
        return count
    }
}

private actor RecordingPublicationTracker: ZipOutputPublicationTracking {
    struct Preparation: Sendable {
        let stagingExisted: Bool
        let destinationExisted: Bool
        let destination: URL
    }

    private(set) var preparation: Preparation?

    func preparePublication(stagingDirectory: URL, destinationDirectory: URL) {
        preparation = Preparation(
            stagingExisted: FileManager.default.fileExists(atPath: stagingDirectory.path),
            destinationExisted: FileManager.default.fileExists(atPath: destinationDirectory.path),
            destination: destinationDirectory.standardizedFileURL
        )
    }

    func cancelPublication(stagingDirectory: URL) {}
}

private struct PassthroughDecoder: LogDecoder {
    let format: LogFormat

    func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog {
        .complete(data)
    }
}

private struct FixedResultDecoder: LogDecoder {
    let format: LogFormat
    let result: DecodedLog

    func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog {
        result
    }
}
