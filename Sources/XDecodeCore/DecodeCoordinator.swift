import Darwin
import Foundation

public typealias DecoderResolver = @Sendable (DecodeRequest) async throws -> any LogDecoder

public actor DecodeCoordinator {
    private let fileManager: FileManager
    private let decoderResolver: DecoderResolver

    public init(
        fileManager: FileManager = .default,
        decoderResolver: @escaping DecoderResolver
    ) {
        self.fileManager = fileManager
        self.decoderResolver = decoderResolver
    }

    public func decode(_ request: DecodeRequest) async -> DecodeResult {
        let sourceURL = request.sourceURL.standardizedFileURL
        let directory = sourceURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".xdecode-\(UUID().uuidString).tmp")
        var outputURL: URL?

        do {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw DecodeError.fileOperation("源文件不存在")
            }

            let input = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            let decoder = try await decoderResolver(request)
            let decoded = try decoder.decode(input, sourceURL: sourceURL)

            guard decoded.isComplete else {
                return DecodeResult(
                    request: request,
                    state: .failed,
                    outputURL: nil,
                    message: "解密失败：\(decoded.diagnostic ?? "日志未完整解密")；未生成 .log，源文件已保留",
                    sourceDeleted: false
                )
            }
            guard !decoded.data.isEmpty else { throw DecodeError.emptyOutput }

            try decoded.data.write(to: temporaryURL)
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()

            outputURL = try moveToUniqueOutput(temporaryURL: temporaryURL, sourceURL: sourceURL)

            do {
                try fileManager.removeItem(at: sourceURL)
                let message = decoded.diagnostic.map { "\($0)；源文件已永久删除" }
                    ?? "解密完成，源文件已永久删除"
                return DecodeResult(
                    request: request,
                    state: .completed,
                    outputURL: outputURL,
                    message: message,
                    sourceDeleted: true
                )
            } catch {
                let message = decoded.diagnostic.map {
                    "\($0)；源文件删除失败：\(error.localizedDescription)"
                } ?? "解密完成，但源文件删除失败：\(error.localizedDescription)"
                return DecodeResult(
                    request: request,
                    state: .completedWithWarning,
                    outputURL: outputURL,
                    message: message,
                    sourceDeleted: false
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            return DecodeResult(
                request: request,
                state: .failed,
                outputURL: outputURL,
                message: error.localizedDescription,
                sourceDeleted: false
            )
        }
    }

    public static func outputURL(for sourceURL: URL, index: Int = 0) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = index == 0 ? "" : "-\(index)"
        return directory.appendingPathComponent("\(baseName)\(suffix).log", isDirectory: false)
    }

    private func moveToUniqueOutput(temporaryURL: URL, sourceURL: URL) throws -> URL {
        var index = 0
        while true {
            let candidate = Self.outputURL(for: sourceURL, index: index)
            let result = temporaryURL.path.withCString { sourcePath in
                candidate.path.withCString { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                return candidate
            }

            let renameError = errno
            if renameError == EEXIST {
                index += 1
            } else {
                let message = String(cString: strerror(renameError))
                throw DecodeError.fileOperation(message)
            }
        }
    }
}

public enum StandardDecoderResolver {
    public static func make(
        xlogCredentials: @escaping @Sendable (URL) async -> [XlogCredentials],
        loganCredentials: @escaping @Sendable (URL) async throws -> [LoganCredentials]
    ) -> DecoderResolver {
        { request in
            switch request.format {
            case .xlog:
                return XlogDecoder(credentials: await xlogCredentials(request.sourceURL))
            case .mx:
                return MXDecoder()
            case .logan:
                return LoganDecoder(credentials: try await loganCredentials(request.sourceURL))
            case .zip:
                throw DecodeError.unsupportedFormat("ZIP 容器需要通过批量解密流程处理")
            }
        }
    }
}
