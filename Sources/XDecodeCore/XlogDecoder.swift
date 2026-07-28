import Foundation
import P256K

public struct XlogDecoder: LogDecoder {
    public let format = LogFormat.xlog
    private let credentials: [XlogCredentials]

    public init(credentials: [XlogCredentials] = []) {
        self.credentials = credentials
    }

    public func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog {
        guard !data.isEmpty else { throw DecodeError.malformed("Xlog 文件为空") }
        guard var cursor = findFrameStart(in: data) else {
            throw DecodeError.malformed("未找到有效的 Xlog 数据帧")
        }

        var output = Data()
        var diagnostics = Diagnostics()
        var previousSequence: UInt16?
        var preferredCredentialIndex: Int?

        if cursor > 0 {
            diagnostics.damagedSections += 1
            diagnostics.skippedBytes += cursor
        }

        while cursor < data.count {
            guard let frame = try? Frame(data: data, offset: cursor) else {
                diagnostics.damagedSections += 1
                if let recovered = findFrameStart(in: data, startingAt: cursor + 1) {
                    diagnostics.skippedBytes += recovered - cursor
                    cursor = recovered
                    continue
                }
                diagnostics.skippedBytes += data.count - cursor
                break
            }

            diagnostics.totalFrames += 1
            if let previousSequence,
               frame.sequence > 1,
               Int(frame.sequence) != Int(previousSequence) + 1 {
                diagnostics.sequenceGaps += 1
            }
            if frame.sequence != 0 { previousSequence = frame.sequence }

            do {
                let decoded = try decodePayload(frame, preferredCredentialIndex: &preferredCredentialIndex)
                output.append(decoded)
                diagnostics.successfulFrames += 1
            } catch PayloadError.missingCredentials {
                diagnostics.failedFrames += 1
                diagnostics.missingKeyFrames += 1
            } catch PayloadError.noCredentialSucceeded {
                diagnostics.failedFrames += 1
                diagnostics.rejectedKeyFrames += 1
            } catch {
                diagnostics.failedFrames += 1
                diagnostics.invalidPayloadFrames += 1
            }
            cursor = frame.nextOffset
        }

        guard diagnostics.successfulFrames > 0, !output.isEmpty else {
            if diagnostics.missingKeyFrames > 0 {
                throw DecodeError.decodingFailed(
                    "\(diagnostics.failureSummary)；缺少匹配的 Xlog secp256k1 私钥"
                )
            }
            if diagnostics.rejectedKeyFrames > 0 {
                throw DecodeError.decodingFailed(
                    "\(diagnostics.failureSummary)；Xlog 私钥不匹配或加密数据帧损坏"
                )
            }
            throw DecodeError.decodingFailed(
                "\(diagnostics.failureSummary)；没有可输出的日志内容"
            )
        }

        guard diagnostics.isComplete else {
            return .partial(output, diagnostic: diagnostics.message)
        }
        return .complete(output, diagnostic: diagnostics.completeMessage)
    }

    private func decodePayload(
        _ frame: Frame,
        preferredCredentialIndex: inout Int?
    ) throws -> Data {
        guard frame.magic.requiresECDH else {
            return try decompress(frame.payload, magic: frame.magic)
        }
        guard !credentials.isEmpty else { throw PayloadError.missingCredentials }

        var candidateIndices = Array(credentials.indices)
        if let preferredCredentialIndex,
           let index = candidateIndices.firstIndex(of: preferredCredentialIndex) {
            candidateIndices.remove(at: index)
            candidateIndices.insert(preferredCredentialIndex, at: 0)
        }

        for index in candidateIndices {
            do {
                let teaKey = try deriveTEAKey(
                    publicKey: frame.publicKey,
                    privateKeyData: credentials[index].privateKey
                )
                let decrypted = TEA.decrypt(frame.payload, key: teaKey)
                let decoded = try decompress(decrypted, magic: frame.magic)
                preferredCredentialIndex = index
                return decoded
            } catch {
                continue
            }
        }
        throw PayloadError.noCredentialSucceeded
    }

    private func decompress(_ payload: Data, magic: XlogMagic) throws -> Data {
        switch magic {
        case .compress, .compressNoCrypt, .compressECDH:
            return try CompressionUtilities.inflateRaw(payload)
        case .compressChunked:
            return try CompressionUtilities.inflateRaw(try joinChunkedPayload(payload))
        case .syncZstdCrypt, .syncZstdNoCrypt, .asyncZstdCrypt, .asyncZstdNoCrypt:
            return try CompressionUtilities.zstd(payload)
        case .noCompress, .noCompressExtended, .noCompressNoCrypt:
            return payload
        }
    }

    private func joinChunkedPayload(_ data: Data) throws -> Data {
        var cursor = 0
        var joined = Data()
        while cursor < data.count {
            let length = Int(try data.uint16LE(at: cursor))
            cursor += 2
            joined.append(try data.checkedRange(cursor..<(cursor + length)))
            cursor += length
        }
        return joined
    }

    private func deriveTEAKey(publicKey: Data, privateKeyData: Data) throws -> Data {
        guard publicKey.count == 64 else {
            throw DecodeError.decryptionFailed("Xlog ECDH 公钥长度无效")
        }
        var x963 = Data([0x04])
        x963.append(publicKey)

        do {
            let privateKey = try P256K.KeyAgreement.PrivateKey(
                dataRepresentation: privateKeyData,
                format: .uncompressed
            )
            let peerKey = try P256K.KeyAgreement.PublicKey(x963Representation: x963)
            let sharedSecret = privateKey.sharedSecretFromKeyAgreement(with: peerKey, format: .uncompressed)
            let sharedPoint = sharedSecret.withUnsafeBytes { Data($0) }
            guard sharedPoint.count == 65 else {
                throw DecodeError.decryptionFailed("ECDH 共享点长度无效")
            }
            return sharedPoint.subdata(in: 1..<17)
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.decryptionFailed("ECDH：\(error.localizedDescription)")
        }
    }

    private func findFrameStart(in data: Data, startingAt start: Int = 0) -> Int? {
        guard start < data.count else { return nil }
        for offset in start..<data.count {
            if (try? Frame(data: data, offset: offset)) != nil { return offset }
        }
        return nil
    }
}

private extension XlogDecoder {
    enum PayloadError: Error {
        case missingCredentials
        case noCredentialSucceeded
    }

    struct Diagnostics {
        var totalFrames = 0
        var successfulFrames = 0
        var failedFrames = 0
        var missingKeyFrames = 0
        var rejectedKeyFrames = 0
        var invalidPayloadFrames = 0
        var damagedSections = 0
        var skippedBytes = 0
        var sequenceGaps = 0

        var isComplete: Bool {
            failedFrames == 0 && damagedSections == 0 && sequenceGaps == 0
        }

        var message: String {
            var details = ["Xlog 部分解密：成功 \(successfulFrames) 帧，失败 \(failedFrames) 帧"]
            if missingKeyFrames > 0 {
                details.append("\(missingKeyFrames) 个加密帧缺少匹配私钥")
            }
            if rejectedKeyFrames > 0 {
                details.append("\(rejectedKeyFrames) 个加密帧密钥不匹配或已损坏")
            }
            if invalidPayloadFrames > 0 {
                details.append("\(invalidPayloadFrames) 个数据帧解压失败或已损坏")
            }
            if damagedSections > 0 {
                details.append("跳过 \(damagedSections) 段损坏数据（\(skippedBytes) 字节）")
            }
            if sequenceGaps > 0 {
                details.append("检测到 \(sequenceGaps) 处日志序号缺失")
            }
            return details.joined(separator: "；")
        }

        var completeMessage: String {
            "Xlog 解密完成：成功 \(successfulFrames) 帧，失败 0 帧"
        }

        var failureSummary: String {
            "Xlog 解密失败：成功 0 帧，失败 \(failedFrames) 帧"
        }
    }
}

private enum XlogMagic: UInt8 {
    case noCompress = 0x03
    case compress = 0x04
    case compressChunked = 0x05
    case noCompressExtended = 0x06
    case compressECDH = 0x07
    case noCompressNoCrypt = 0x08
    case compressNoCrypt = 0x09
    case syncZstdCrypt = 0x0A
    case syncZstdNoCrypt = 0x0B
    case asyncZstdCrypt = 0x0C
    case asyncZstdNoCrypt = 0x0D

    var keyLength: Int {
        switch self {
        case .noCompress, .compress, .compressChunked: 4
        default: 64
        }
    }

    var requiresECDH: Bool {
        switch self {
        case .compressECDH, .syncZstdCrypt, .asyncZstdCrypt: true
        default: false
        }
    }
}

private struct Frame {
    let magic: XlogMagic
    let sequence: UInt16
    let publicKey: Data
    let payload: Data
    let nextOffset: Int

    init(data: Data, offset: Int) throws {
        guard let magic = XlogMagic(rawValue: try data.uint8(at: offset)) else {
            throw DecodeError.malformed("Xlog Magic 无效")
        }
        let headerLength = 1 + 2 + 1 + 1 + 4 + magic.keyLength
        guard offset + headerLength + 1 <= data.count else {
            throw DecodeError.malformed("Xlog Header 不完整")
        }
        let payloadLength = Int(try data.uint32LE(at: offset + 5))
        let payloadStart = offset + headerLength
        let endMarker = payloadStart + payloadLength
        guard payloadLength >= 0, endMarker < data.count, try data.uint8(at: endMarker) == 0 else {
            throw DecodeError.malformed("Xlog 数据帧长度或结束标记无效")
        }

        self.magic = magic
        self.sequence = try data.uint16LE(at: offset + 1)
        self.publicKey = try data.checkedRange((offset + 9)..<(offset + 9 + magic.keyLength))
        self.payload = try data.checkedRange(payloadStart..<endMarker)
        self.nextOffset = endMarker + 1
    }
}

private enum TEA {
    static func decrypt(_ data: Data, key: Data) -> Data {
        guard key.count >= 16 else { return data }
        let completeLength = data.count / 8 * 8
        var output = Data(capacity: data.count)
        let keyWords = (0..<4).map { keyWord(key, offset: $0 * 4) }

        var offset = 0
        while offset < completeLength {
            var v0 = keyWord(data, offset: offset)
            var v1 = keyWord(data, offset: offset + 4)
            let delta: UInt32 = 0x9E37_79B9
            var sum = delta &<< 4

            for _ in 0..<16 {
                v1 = v1 &- (((v0 &<< 4) &+ keyWords[2]) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ keyWords[3]))
                v0 = v0 &- (((v1 &<< 4) &+ keyWords[0]) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ keyWords[1]))
                sum = sum &- delta
            }
            appendLittleEndian(v0, to: &output)
            appendLittleEndian(v1, to: &output)
            offset += 8
        }
        if completeLength < data.count { output.append(data.suffix(from: completeLength)) }
        return output
    }

    private static func keyWord(_ data: Data, offset: Int) -> UInt32 {
        (try? data.uint32LE(at: offset)) ?? 0
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
