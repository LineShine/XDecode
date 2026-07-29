import Darwin
import Foundation
import ZIPFoundation

public typealias ArchiveEntryFormatResolver = @Sendable (URL) async -> LogFormat?

public protocol ZipOutputPublicationTracking: Sendable {
    func preparePublication(stagingDirectory: URL, destinationDirectory: URL) async throws
    func cancelPublication(stagingDirectory: URL) async
}

public actor ZipDecodeCoordinator {
    private struct ArchiveItem {
        let entry: Entry
        let relativePath: String
        let format: LogFormat?
    }

    private let fileManager: FileManager
    private let decoderResolver: DecoderResolver
    private let entryFormatResolver: ArchiveEntryFormatResolver
    private let publicationTracker: (any ZipOutputPublicationTracking)?
    private let maximumArchiveEntryCount = 1_000
    private let maximumLogCount = 100
    private let maximumEntrySize = DecodeLimits.maximumInputFileSize
    private let maximumTotalSize: UInt64 = 1024 * 1024 * 1024

    public init(
        fileManager: FileManager = .default,
        decoderResolver: @escaping DecoderResolver,
        entryFormatResolver: @escaping ArchiveEntryFormatResolver = {
            try? LogFormat.detect(from: $0)
        },
        publicationTracker: (any ZipOutputPublicationTracking)? = nil
    ) {
        self.fileManager = fileManager
        self.decoderResolver = decoderResolver
        self.entryFormatResolver = entryFormatResolver
        self.publicationTracker = publicationTracker
    }

    public func decode(_ request: DecodeRequest) async -> DecodeResult {
        let sourceURL = request.sourceURL.standardizedFileURL
        var temporaryDirectory: URL?

        do {
            guard request.format == .zip else {
                throw DecodeError.unsupportedFormat(request.format.rawValue)
            }
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw DecodeError.fileOperation("源 ZIP 不存在")
            }
            try DecodeLimits.validateInputFile(at: sourceURL, description: "源 ZIP")

            let archive: Archive
            do {
                archive = try Archive(url: sourceURL, accessMode: .read)
            } catch {
                throw DecodeError.malformed("ZIP 无法读取：\(error.localizedDescription)")
            }

            let items = try await inspectEntries(in: archive, sourceURL: sourceURL)
            let logCount = items.filter { $0.format != nil }.count
            guard logCount > 0 else {
                return DecodeResult(
                    request: request,
                    state: .skipped,
                    outputURL: nil,
                    message: "ZIP 中没有符合当前规则的 Xlog、MX 或 Logan 日志；未生成输出目录，源 ZIP 已保留",
                    sourceDeleted: false
                )
            }
            guard logCount <= maximumLogCount else {
                throw DecodeError.decodingFailed("ZIP 中日志数量超过 \(maximumLogCount) 个")
            }

            let parentDirectory = sourceURL.deletingLastPathComponent()
            let stagingDirectory = parentDirectory.appendingPathComponent(
                ".xdecode-zip-\(UUID().uuidString).tmp",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            temporaryDirectory = stagingDirectory

            for item in items where item.format == nil {
                try extractPreservedItem(item, from: archive, to: stagingDirectory)
            }

            var decodedCount = 0
            var decodedOutputSize = 0
            var failedLogNames = [String]()
            for item in items {
                guard let format = item.format else { continue }
                let sourceEntryURL = sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(item.relativePath, isDirectory: false)
                let payload = try extractLogData(item, from: archive)
                let entryRequest = try DecodeRequest(
                    sourceURL: sourceEntryURL,
                    format: format,
                    origin: request.origin,
                    requestedAt: request.requestedAt
                )

                var decodedOutputURL: URL?
                do {
                    let decoder = try await decoderResolver(entryRequest)
                    let decoded = try decoder.decode(payload, sourceURL: sourceEntryURL)
                    guard decoded.isComplete else {
                        throw DecodeError.decodingFailed(decoded.diagnostic ?? "日志未完整解密")
                    }
                    guard !decoded.data.isEmpty else { throw DecodeError.emptyOutput }
                    try DecodeLimits.validateDecompressedOutputSize(
                        currentSize: decodedOutputSize,
                        appending: decoded.data.count
                    )

                    let outputURL = uniqueDecodedOutput(
                        for: item.relativePath,
                        in: stagingDirectory
                    )
                    decodedOutputURL = outputURL
                    try write(decoded.data, to: outputURL)
                    decodedOutputSize += decoded.data.count
                    decodedCount += 1
                } catch {
                    if let decodedOutputURL {
                        try? fileManager.removeItem(at: decodedOutputURL)
                    }
                    let originalURL = stagingDirectory.appendingPathComponent(
                        item.relativePath,
                        isDirectory: false
                    )
                    do {
                        try write(payload, to: originalURL)
                    } catch {
                        throw DecodeError.fileOperation(
                            "无法保留原始日志 \(item.relativePath)：\(error.localizedDescription)"
                        )
                    }
                    failedLogNames.append((item.relativePath as NSString).lastPathComponent)
                }
            }

            let outputDirectory = try await moveToUniqueOutputDirectory(
                temporaryDirectory: stagingDirectory,
                sourceURL: sourceURL
            )
            temporaryDirectory = nil

            let failedCount = failedLogNames.count
            let state: DecodeState
            let message: String
            if failedCount == 0 {
                state = .completed
                message = "ZIP 批量解密成功：\(decodedCount)/\(logCount) 个日志已生成 .log；源 ZIP 已保留"
            } else if decodedCount == 0 {
                state = .failed
                message = "ZIP 批量解密失败：0/\(logCount) 个日志成功；全部原始日志已保留在输出目录；源 ZIP 已保留"
            } else {
                state = .partiallyCompleted
                let names = failedLogNames.prefix(5).joined(separator: "、")
                let remaining = failedCount > 5 ? "等 \(failedCount) 个文件" : ""
                message = "ZIP 批量部分成功：成功 \(decodedCount) 个，失败 \(failedCount) 个；\(names)\(remaining) 已保留原始日志；源 ZIP 已保留"
            }
            return DecodeResult(
                request: request,
                state: state,
                outputURL: outputDirectory,
                message: message,
                sourceDeleted: false
            )
        } catch {
            if let temporaryDirectory {
                await publicationTracker?.cancelPublication(stagingDirectory: temporaryDirectory)
                try? fileManager.removeItem(at: temporaryDirectory)
            }
            return DecodeResult(
                request: request,
                state: .failed,
                outputURL: nil,
                message: "\(error.localizedDescription)；未生成输出目录，源 ZIP 已保留",
                sourceDeleted: false
            )
        }
    }

    private func inspectEntries(in archive: Archive, sourceURL: URL) async throws -> [ArchiveItem] {
        var items = [ArchiveItem]()
        var seenPaths = Set<String>()
        var totalSize: UInt64 = 0
        var archiveEntryCount = 0

        for entry in archive {
            archiveEntryCount += 1
            guard archiveEntryCount <= maximumArchiveEntryCount else {
                throw DecodeError.decodingFailed("ZIP 条目总数超过 \(maximumArchiveEntryCount) 个")
            }
            let relativePath = try validatedRelativePath(entry.path)
            let comparisonPath = relativePath.lowercased()
            guard seenPaths.insert(comparisonPath).inserted else {
                throw DecodeError.decodingFailed("ZIP 包含重复路径：\(relativePath)")
            }
            if isMetadataPath(relativePath) { continue }

            if entry.type != .directory {
                guard entry.uncompressedSize <= maximumEntrySize else {
                    throw DecodeError.decodingFailed("ZIP 条目超过 500 MB：\(relativePath)")
                }
                let (newTotal, overflow) = totalSize.addingReportingOverflow(entry.uncompressedSize)
                guard !overflow, newTotal <= maximumTotalSize else {
                    throw DecodeError.decodingFailed("ZIP 解压后总大小超过 1 GB")
                }
                totalSize = newTotal
            }

            var format: LogFormat?
            if entry.type == .file {
                let virtualURL = sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(relativePath, isDirectory: false)
                let detected = await entryFormatResolver(virtualURL)
                if let detected, [.xlog, .mx, .logan].contains(detected) {
                    format = detected
                }
            }
            items.append(ArchiveItem(entry: entry, relativePath: relativePath, format: format))
        }
        return items
    }

    private func extractPreservedItem(
        _ item: ArchiveItem,
        from archive: Archive,
        to stagingDirectory: URL
    ) throws {
        let destinationURL = stagingDirectory.appendingPathComponent(
            item.relativePath,
            isDirectory: item.entry.type == .directory
        )
        do {
            let checksum = try archive.extract(
                item.entry,
                to: destinationURL,
                bufferSize: 64 * 1024
            )
            guard checksum == item.entry.checksum else {
                throw DecodeError.decodingFailed("\(item.relativePath) ZIP CRC 校验失败")
            }
            if item.entry.type == .file {
                let handle = try FileHandle(forWritingTo: destinationURL)
                try handle.synchronize()
                try handle.close()
            }
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.decodingFailed(
                "\(item.relativePath) 解压失败：\(error.localizedDescription)"
            )
        }
    }

    private func extractLogData(_ item: ArchiveItem, from archive: Archive) throws -> Data {
        let entry = item.entry
        let relativePath = item.relativePath
        let entrySizeLimit = maximumEntrySize
        var payload = Data()
        payload.reserveCapacity(Int(entry.uncompressedSize))
        let checksum: CRC32
        do {
            checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                let nextSize = UInt64(payload.count) + UInt64(chunk.count)
                guard nextSize <= entrySizeLimit else {
                    throw DecodeError.decodingFailed(
                        "\(relativePath) 解压后超过大小限制"
                    )
                }
                payload.append(chunk)
            }
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.decodingFailed(
                "\(relativePath) 解压失败：\(error.localizedDescription)"
            )
        }
        guard checksum == entry.checksum else {
            throw DecodeError.decodingFailed("\(relativePath) ZIP CRC 校验失败")
        }
        guard UInt64(payload.count) == entry.uncompressedSize else {
            throw DecodeError.decodingFailed("\(relativePath) 解压后的大小不完整")
        }
        return payload
    }

    private func uniqueDecodedOutput(for relativePath: String, in directory: URL) -> URL {
        let path = relativePath as NSString
        let parent = path.deletingLastPathComponent
        let baseName = (path.lastPathComponent as NSString).deletingPathExtension
        var index = 0

        while true {
            let suffix = index == 0 ? "" : "-\(index)"
            let fileName = "\(baseName)\(suffix).log"
            let candidatePath = parent.isEmpty ? fileName : "\(parent)/\(fileName)"
            let candidate = directory.appendingPathComponent(candidatePath, isDirectory: false)
            if !pathExists(candidate) { return candidate }
            index += 1
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func pathExists(_ url: URL) -> Bool {
        var fileStatus = stat()
        return url.path.withCString { lstat($0, &fileStatus) } == 0
    }

    private func moveToUniqueOutputDirectory(
        temporaryDirectory: URL,
        sourceURL: URL
    ) async throws -> URL {
        let parent = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var index = 0

        while true {
            let suffix = index == 0 ? "" : "-\(index)"
            let candidate = parent.appendingPathComponent("\(baseName)\(suffix)", isDirectory: true)
            try await publicationTracker?.preparePublication(
                stagingDirectory: temporaryDirectory,
                destinationDirectory: candidate
            )
            let result = temporaryDirectory.path.withCString { sourcePath in
                candidate.path.withCString { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return candidate }

            let renameError = errno
            if renameError == EEXIST {
                index += 1
            } else {
                throw DecodeError.fileOperation(String(cString: strerror(renameError)))
            }
        }
    }

    private func validatedRelativePath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\0") else {
            throw DecodeError.decodingFailed("ZIP 包含不安全路径：\(rawPath)")
        }

        var safeComponents = [Substring]()
        for component in normalized.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            guard component != ".." else {
                throw DecodeError.decodingFailed("ZIP 包含路径穿越条目：\(rawPath)")
            }
            safeComponents.append(component)
        }
        guard let first = safeComponents.first,
              !first.hasSuffix(":") else {
            throw DecodeError.decodingFailed("ZIP 包含不安全路径：\(rawPath)")
        }
        return safeComponents.joined(separator: "/")
    }

    private func isMetadataPath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        return components.contains("__MACOSX")
            || components.last.map { $0.hasPrefix("._") } == true
    }
}
