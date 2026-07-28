import CommonCrypto
import Foundation

public struct LoganDecoder: LogDecoder {
    public let format = LogFormat.logan
    private let credentials: [LoganCredentials]
    // The reference Objective-C decoder zero-fills empty Key/IV strings to one AES block.
    private static let unkeyedCredentials = try! LoganCredentials(
        key: Data(repeating: 0, count: kCCKeySizeAES128),
        iv: Data(repeating: 0, count: kCCBlockSizeAES128)
    )

    public init(credentials: LoganCredentials) {
        self.credentials = [credentials]
    }

    public init(credentials: [LoganCredentials]) {
        self.credentials = credentials
    }

    public func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog {
        let candidates = [Self.unkeyedCredentials] + credentials.filter {
            $0 != Self.unkeyedCredentials
        }
        var lastError: (any Error)?
        for candidate in candidates {
            do {
                return try decode(data, credentials: candidate)
            } catch {
                lastError = error
            }
        }
        guard !credentials.isEmpty else {
            throw DecodeError.missingCredentials(.logan)
        }
        if credentials.count == 1, let lastError {
            throw lastError
        }
        throw DecodeError.decryptionFailed(
            "\(credentials.count) 个匹配的 Logan Key/IV 均无法解密，密钥不匹配或日志损坏"
        )
    }

    private func decode(_ data: Data, credentials: LoganCredentials) throws -> DecodedLog {
        guard !data.isEmpty else { throw DecodeError.malformed("Logan 文件为空") }
        var cursor = 0
        var output = Data()
        var decodedFrames = 0

        while cursor < data.count {
            let marker = try data.uint8(at: cursor)
            guard marker == 0x01 else {
                throw DecodeError.malformed("Logan 帧标记无效：0x\(String(marker, radix: 16))")
            }
            cursor += 1
            let encryptedSize = Int(try data.uint32BE(at: cursor))
            cursor += 4
            guard encryptedSize > 0, encryptedSize < 10_000_000 else {
                throw DecodeError.malformed("Logan 数据块长度无效：\(encryptedSize)")
            }

            let encrypted = try data.checkedRange(cursor..<(cursor + encryptedSize))
            cursor += encryptedSize
            let isUnfinishedFinalFrame = cursor == data.count
            output.append(try decodeFrame(
                encrypted,
                credentials: credentials,
                allowsUnfinishedStream: isUnfinishedFinalFrame
            ))
            decodedFrames += 1

            if cursor < data.count {
                let delimiter = try data.uint8(at: cursor)
                guard delimiter == 0 else {
                    throw DecodeError.malformed("Logan 帧分隔符无效")
                }
                cursor += 1
            }
        }

        guard decodedFrames > 0, !output.isEmpty else { throw DecodeError.emptyOutput }
        return .complete(output)
    }

    private func decodeFrame(
        _ encrypted: Data,
        credentials: LoganCredentials,
        allowsUnfinishedStream: Bool
    ) throws -> Data {
        // Match SwiftyLoganTool first, then retain compatibility with legacy NoPadding frames.
        let options = [CCOptions(kCCOptionPKCS7Padding), CCOptions(0)]
        for option in options {
            do {
                let decrypted = try AES.decryptCBC(
                    encrypted,
                    credentials: credentials,
                    options: option
                )
                return try decodeCompressedFrame(
                    decrypted,
                    allowsUnfinishedStream: allowsUnfinishedStream && option == 0
                )
            } catch {
                continue
            }
        }

        throw DecodeError.decryptionFailed(
            "Logan Key/IV 不匹配，或 AES/压缩数据损坏"
        )
    }

    private func decodeCompressedFrame(
        _ decrypted: Data,
        allowsUnfinishedStream: Bool
    ) throws -> Data {
        let output: Data
        do {
            output = try CompressionUtilities.inflateZlibOrGzip(decrypted)
        } catch let decompressionError as DecodeError {
            guard allowsUnfinishedStream else { throw decompressionError }
            return try recoverUnfinishedFrame(decrypted)
        }

        guard !output.isEmpty else { throw DecodeError.emptyOutput }
        guard String(data: output, encoding: .utf8) != nil else {
            throw DecodeError.decodingFailed("Logan 解密内容不是有效的 UTF-8 文本")
        }
        return output
    }

    private func recoverUnfinishedFrame(_ decrypted: Data) throws -> Data {
        // CLogan can persist full AES blocks before the active gzip stream has been finalized.
        let recovered = try CompressionUtilities.inflateUnfinishedZlibOrGzip(decrypted)
        guard let lastNewline = recovered.lastIndex(of: 0x0A) else {
            throw DecodeError.decompressionFailed("Logan 未完成末帧没有完整日志行")
        }
        let completeLines = Data(recovered.prefix(through: lastNewline))
        guard !completeLines.isEmpty else { throw DecodeError.emptyOutput }
        guard String(data: completeLines, encoding: .utf8) != nil else {
            throw DecodeError.decodingFailed("Logan 未完成末帧不是有效的 UTF-8 文本")
        }
        return completeLines
    }
}

private enum AES {
    static func decryptCBC(
        _ data: Data,
        credentials: LoganCredentials,
        options: CCOptions
    ) throws -> Data {
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw DecodeError.decryptionFailed("AES-CBC 数据长度不是 16 的倍数")
        }
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0

        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                credentials.key.withUnsafeBytes { keyBuffer in
                    credentials.iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBuffer.baseAddress,
                            credentials.key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress,
                            data.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw DecodeError.decryptionFailed("CommonCrypto 状态码 \(status)")
        }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
