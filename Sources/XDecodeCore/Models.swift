import Foundation
import P256K

public enum LogFormat: String, Codable, CaseIterable, Sendable {
    case xlog
    case mx
    case logan
    case zip

    public static func detect(from url: URL) throws -> LogFormat {
        if let format = LogFormat(rawValue: url.pathExtension.lowercased()) {
            return format
        }
        let fileName = url.lastPathComponent
        if fileName.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return .logan
        }
        throw DecodeError.unsupportedFormat(url.pathExtension)
    }
}

public enum DecodeOrigin: String, Codable, Sendable {
    case automatic
    case dragAndDrop
    case filePicker
    case finder
    case openWith
}

public struct DecodeRequest: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let format: LogFormat
    public let origin: DecodeOrigin
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        format: LogFormat? = nil,
        origin: DecodeOrigin,
        requestedAt: Date = Date()
    ) throws {
        self.id = id
        self.sourceURL = sourceURL
        self.format = try format ?? LogFormat.detect(from: sourceURL)
        self.origin = origin
        self.requestedAt = requestedAt
    }
}

public enum DecodeState: String, Codable, Sendable {
    case completed
    case partiallyCompleted
    case completedWithWarning
    case skipped
    case failed
}

public struct DecodeResult: Codable, Identifiable, Sendable {
    public let id: UUID
    public let request: DecodeRequest
    public let state: DecodeState
    public let outputURL: URL?
    public let message: String
    public let sourceDeleted: Bool
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        request: DecodeRequest,
        state: DecodeState,
        outputURL: URL?,
        message: String,
        sourceDeleted: Bool,
        finishedAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.state = state
        self.outputURL = outputURL
        self.message = message
        self.sourceDeleted = sourceDeleted
        self.finishedAt = finishedAt
    }
}

public struct DecodedLog: Equatable, Sendable {
    public let data: Data
    public let isComplete: Bool
    public let diagnostic: String?

    public init(data: Data, isComplete: Bool, diagnostic: String? = nil) {
        self.data = data
        self.isComplete = isComplete
        self.diagnostic = diagnostic
    }

    public static func complete(_ data: Data, diagnostic: String? = nil) -> DecodedLog {
        DecodedLog(data: data, isComplete: true, diagnostic: diagnostic)
    }

    public static func partial(_ data: Data, diagnostic: String) -> DecodedLog {
        DecodedLog(data: data, isComplete: false, diagnostic: diagnostic)
    }
}

public struct XlogCredentials: Codable, Equatable, Sendable {
    public let privateKey: Data

    public init(privateKey: Data) throws {
        guard privateKey.count == 32 else {
            throw DecodeError.invalidCredentials("Xlog secp256k1 私钥必须是 32 字节（64 位 Hex）")
        }
        do {
            _ = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        } catch {
            throw DecodeError.invalidCredentials("Xlog secp256k1 私钥不是有效标量")
        }
        self.privateKey = privateKey
    }

    public init(privateKeyHex: String) throws {
        var normalized = privateKeyHex.filter { !$0.isWhitespace }
        if normalized.lowercased().hasPrefix("0x") {
            normalized.removeFirst(2)
        }
        guard normalized.count == 64, let data = Data(hexadecimal: normalized) else {
            throw DecodeError.invalidCredentials("Xlog secp256k1 私钥必须是 64 位 Hex")
        }
        try self.init(privateKey: data)
    }
}

public struct LoganCredentials: Codable, Equatable, Sendable {
    public let key: Data
    public let iv: Data

    public init(key: Data, iv: Data) throws {
        guard key.count >= 16 else {
            throw DecodeError.invalidCredentials("Logan AES Key 至少需要 16 字节")
        }
        guard iv.count >= 16 else {
            throw DecodeError.invalidCredentials("Logan AES IV 至少需要 16 字节")
        }
        self.key = Data(key.prefix(16))
        self.iv = Data(iv.prefix(16))
    }

    public init(key: String, iv: String) throws {
        try self.init(key: Data(key.utf8), iv: Data(iv.utf8))
    }
}

public protocol LogDecoder: Sendable {
    var format: LogFormat { get }
    func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog
}

public enum DecodeError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case malformed(String)
    case invalidCredentials(String)
    case missingCredentials(LogFormat)
    case decodingFailed(String)
    case decompressionFailed(String)
    case outputLimitExceeded
    case decryptionFailed(String)
    case emptyOutput
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value):
            return "不支持的日志格式：\(value.isEmpty ? "无扩展名" : value)"
        case .malformed(let message):
            return "日志内容损坏：\(message)"
        case .invalidCredentials(let message):
            return message
        case .missingCredentials(.xlog):
            return "没有匹配且可读取的 Xlog secp256k1 私钥方案"
        case .missingCredentials(.logan):
            return "没有匹配的 Logan Key/IV 方案"
        case .missingCredentials(.mx):
            return "MX 不需要密钥方案"
        case .missingCredentials(.zip):
            return "ZIP 容器本身不使用日志密钥"
        case .decodingFailed(let message):
            return message
        case .decompressionFailed(let message):
            return "解压失败：\(message)"
        case .outputLimitExceeded:
            return "解压输出超过单任务 1 GiB 大小限制"
        case .decryptionFailed(let message):
            return "解密失败：\(message)"
        case .emptyOutput:
            return "解密结果为空"
        case .fileOperation(let message):
            return "文件操作失败：\(message)"
        }
    }
}
