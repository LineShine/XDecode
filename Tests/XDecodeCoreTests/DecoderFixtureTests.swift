import CommonCrypto
import CZlib
import Foundation
import Testing
@testable import XDecodeCore

@Suite("Decoder fixtures")
struct DecoderFixtureTests {
    private let credentials = try! LoganCredentials(
        key: "0123456789067890",
        iv: "0123456789067890"
    )

    @Test("Xlog decodes plain and raw-zlib frames")
    func xlogFixtures() throws {
        let decoder = XlogDecoder()
        let plain = Data("plain xlog\n".utf8)
        let compressed = Data("compressed xlog\n".utf8)

        let plainResult = try decoder.decode(
            xlogFrame(magic: 0x08, payload: plain),
            sourceURL: URL(fileURLWithPath: "/tmp/plain.xlog")
        )
        let compressedResult = try decoder.decode(
            xlogFrame(magic: 0x09, payload: try deflate(compressed, windowBits: -MAX_WBITS)),
            sourceURL: URL(fileURLWithPath: "/tmp/compressed.xlog")
        )

        #expect(plainResult.data == plain)
        #expect(compressedResult.data == compressed)
    }

    @Test("MX decodes a FlatBuffers log item")
    func mxFixture() throws {
        let result = try MXDecoder().decode(
            mxFile(),
            sourceURL: URL(fileURLWithPath: "/tmp/sample.mx")
        )
        let line = try #require(String(data: result.data, encoding: .utf8))

        #expect(line.contains(" I ['network', 'api'] hello from mx"))
        #expect(line.hasSuffix("\n"))
    }

    @Test("Logan decrypts AES-CBC and gzip frames")
    func loganFixture() throws {
        let expected = Data("logan fixture\n".utf8)
        let compressed = try deflate(expected, windowBits: MAX_WBITS + 16)
        let encrypted = try encryptAES(compressed, credentials: credentials)
        var fixture = Data([0x01])
        fixture.appendUInt32BE(UInt32(encrypted.count))
        fixture.append(encrypted)
        fixture.append(0x00)

        let result = try LoganDecoder(credentials: credentials).decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/sample.logan")
        )
        #expect(result.data == expected)
    }

    @Test("Logan auto-detects zlib streams used by compatible tools")
    func loganZlibFixture() throws {
        let expected = Data("logan zlib fixture\n".utf8)
        let compressed = try deflate(expected, windowBits: MAX_WBITS)
        let encrypted = try encryptAES(compressed, credentials: credentials)

        let result = try LoganDecoder(credentials: credentials).decode(
            loganFrame(encrypted),
            sourceURL: URL(fileURLWithPath: "/tmp/zlib.logan")
        )
        #expect(result.data == expected)
    }

    @Test("Logan accepts AES-CBC NoPadding frames with zero-filled trailing bytes")
    func loganNoPaddingFixture() throws {
        let expected = Data("logan no-padding fixture\n".utf8)
        var compressed = try deflate(expected, windowBits: MAX_WBITS + 16)
        let trailingByteCount = kCCBlockSizeAES128 - compressed.count % kCCBlockSizeAES128
        compressed.append(Data(repeating: 0, count: trailingByteCount))
        let encrypted = try encryptAESNoPadding(compressed, credentials: credentials)
        var fixture = Data([0x01])
        fixture.appendUInt32BE(UInt32(encrypted.count))
        fixture.append(encrypted)
        fixture.append(0x00)

        let result = try LoganDecoder(credentials: credentials).decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/no-padding.logan")
        )
        #expect(result.data == expected)
    }

    @Test("Logan decodes files written with an empty key and IV")
    func loganUnkeyedFixture() throws {
        let unkeyed = try LoganCredentials(
            key: Data(repeating: 0, count: kCCKeySizeAES128),
            iv: Data(repeating: 0, count: kCCBlockSizeAES128)
        )
        let expected = Data("unkeyed logan fixture\n".utf8)
        let encrypted = try encryptAES(
            deflate(expected, windowBits: MAX_WBITS + 16),
            credentials: unkeyed
        )

        for candidates in [[], [credentials]] {
            let result = try LoganDecoder(credentials: candidates).decode(
                loganFrame(encrypted),
                sourceURL: URL(fileURLWithPath: "/tmp/unkeyed-logan")
            )
            #expect(result.data == expected)
        }
    }

    @Test("Logan recovers complete lines from an unfinished final writer frame")
    func loganUnfinishedFinalFrame() throws {
        let expected = Data((0..<500).map { "logan active line \($0)\n" }.joined().utf8)
        let compressed = try deflateSyncFlushed(expected, windowBits: MAX_WBITS + 16)
        let encryptedLength = compressed.count / kCCBlockSizeAES128 * kCCBlockSizeAES128
        let encrypted = try encryptAESNoPadding(
            Data(compressed.prefix(encryptedLength)),
            credentials: credentials
        )

        let result = try LoganDecoder(credentials: credentials).decode(
            loganFrame(encrypted, delimiter: nil),
            sourceURL: URL(fileURLWithPath: "/tmp/unfinished-logan")
        )

        #expect(!result.data.isEmpty)
        #expect(expected.starts(with: result.data))
        #expect(result.data.last == 0x0A)
    }

    @Test("Logan decodes multiple frames when the final delimiter is omitted")
    func loganMultipleFrames() throws {
        let first = Data("first logan frame\n".utf8)
        let second = Data("second logan frame\n".utf8)
        let firstEncrypted = try encryptAES(
            deflate(first, windowBits: MAX_WBITS + 16),
            credentials: credentials
        )
        let secondEncrypted = try encryptAES(
            deflate(second, windowBits: MAX_WBITS),
            credentials: credentials
        )
        var fixture = loganFrame(firstEncrypted)
        fixture.append(loganFrame(secondEncrypted, delimiter: nil))

        let result = try LoganDecoder(credentials: credentials).decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/multiple.logan")
        )
        #expect(result.data == first + second)
    }

    @Test("Logan rejects an incorrect key")
    func loganWrongKey() throws {
        let expected = Data("secret logan fixture\n".utf8)
        let compressed = try deflate(expected, windowBits: MAX_WBITS + 16)
        let encrypted = try encryptAES(compressed, credentials: credentials)
        var fixture = Data([0x01])
        fixture.appendUInt32BE(UInt32(encrypted.count))
        fixture.append(encrypted)
        fixture.append(0x00)
        let incorrect = try LoganCredentials(key: "1111111111111111", iv: "2222222222222222")

        #expect(throws: (any Error).self) {
            try LoganDecoder(credentials: incorrect).decode(
                fixture,
                sourceURL: URL(fileURLWithPath: "/tmp/wrong-key.logan")
            )
        }
    }

    @Test("Logan tries every matching credential until one decrypts the complete file")
    func loganTriesMatchingCredentials() throws {
        let expected = Data("candidate logan fixture\n".utf8)
        let compressed = try deflate(expected, windowBits: MAX_WBITS + 16)
        let encrypted = try encryptAES(compressed, credentials: credentials)
        var fixture = Data([0x01])
        fixture.appendUInt32BE(UInt32(encrypted.count))
        fixture.append(encrypted)
        fixture.append(0x00)
        let incorrect = try LoganCredentials(key: "1111111111111111", iv: "2222222222222222")

        let result = try LoganDecoder(credentials: [incorrect, credentials]).decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/candidates.logan")
        )
        #expect(result.data == expected)
    }

    @Test("Logan rejects the whole file when any frame fails")
    func loganRejectsPartialFiles() throws {
        let expected = Data("complete frame\n".utf8)
        let compressed = try deflate(expected, windowBits: MAX_WBITS + 16)
        let encrypted = try encryptAES(compressed, credentials: credentials)
        var fixture = Data([0x01])
        fixture.appendUInt32BE(UInt32(encrypted.count))
        fixture.append(encrypted)
        fixture.append(0x00)
        fixture.append(0x01)
        fixture.appendUInt32BE(16)
        fixture.append(Data(repeating: 0xA5, count: 16))
        fixture.append(0x00)

        #expect(throws: (any Error).self) {
            try LoganDecoder(credentials: credentials).decode(
                fixture,
                sourceURL: URL(fileURLWithPath: "/tmp/partial.logan")
            )
        }
    }

    @Test("Logan rejects malformed framing instead of scanning past errors")
    func loganRejectsMalformedFraming() throws {
        let compressed = try deflate(Data("valid frame\n".utf8), windowBits: MAX_WBITS + 16)
        let encrypted = try encryptAES(compressed, credentials: credentials)

        var truncated = Data([0x01])
        truncated.appendUInt32BE(UInt32(encrypted.count))
        truncated.append(encrypted.prefix(encrypted.count / 2))

        var leadingGarbage = Data([0x7F])
        leadingGarbage.append(loganFrame(encrypted))

        var missingMiddleDelimiter = loganFrame(encrypted, delimiter: nil)
        missingMiddleDelimiter.append(loganFrame(encrypted))

        let fixtures = [
            truncated,
            leadingGarbage,
            loganFrame(encrypted, delimiter: 0x7F),
            missingMiddleDelimiter,
        ]
        for fixture in fixtures {
            #expect(throws: (any Error).self) {
                try LoganDecoder(credentials: credentials).decode(
                    fixture,
                    sourceURL: URL(fileURLWithPath: "/tmp/malformed.logan")
                )
            }
        }
    }

    @Test("Logan rejects decrypted frames that are not UTF-8 text")
    func loganRejectsNonUTF8() throws {
        let compressed = try deflate(Data([0xFF, 0xFE, 0xFD]), windowBits: MAX_WBITS + 16)
        let encrypted = try encryptAES(compressed, credentials: credentials)

        #expect(throws: (any Error).self) {
            try LoganDecoder(credentials: credentials).decode(
                loganFrame(encrypted),
                sourceURL: URL(fileURLWithPath: "/tmp/non-utf8.logan")
            )
        }
    }

    @Test("All decoders reject corrupt input", arguments: [LogFormat.xlog, .mx, .logan])
    func corruptFixtures(format: LogFormat) throws {
        let decoder: any LogDecoder
        switch format {
        case .xlog:
            decoder = XlogDecoder()
        case .mx:
            decoder = MXDecoder()
        case .logan:
            decoder = LoganDecoder(credentials: credentials)
        case .zip:
            throw DecodeError.unsupportedFormat("ZIP 由批量协调器测试")
        }

        #expect(throws: (any Error).self) {
            try decoder.decode(
                Data([0xFF, 0x00, 0x01]),
                sourceURL: URL(fileURLWithPath: "/tmp/corrupt.\(format.rawValue)")
            )
        }
    }

    private func xlogFrame(magic: UInt8, payload: Data) -> Data {
        var data = Data([magic])
        data.appendUInt16LE(1)
        data.append(contentsOf: [0, 0])
        data.appendUInt32LE(UInt32(payload.count))
        data.append(Data(repeating: 0, count: 64))
        data.append(payload)
        data.append(0)
        return data
    }

    private func loganFrame(_ encrypted: Data, delimiter: UInt8? = 0) -> Data {
        var data = Data([0x01])
        data.appendUInt32BE(UInt32(encrypted.count))
        data.append(encrypted)
        if let delimiter { data.append(delimiter) }
        return data
    }

    private func mxFile() -> Data {
        let tableStart = 24
        let tagStart = 48
        let messageStart = 64
        let tag = Data("network,api".utf8)
        let message = Data("hello from mx".utf8)
        var item = Data(repeating: 0, count: messageStart + 4 + message.count + 1)

        item.writeUInt32LE(UInt32(tableStart), at: 0)
        item.writeUInt16LE(18, at: 4)
        item.writeUInt16LE(24, at: 6)
        item.writeUInt16LE(4, at: 10)
        item.writeUInt16LE(8, at: 12)
        item.writeUInt16LE(12, at: 14)
        item.writeUInt16LE(16, at: 20)

        item.writeUInt32LE(UInt32(tableStart - 4), at: tableStart)
        item.writeUInt32LE(UInt32(tagStart - (tableStart + 4)), at: tableStart + 4)
        item.writeUInt32LE(UInt32(messageStart - (tableStart + 8)), at: tableStart + 8)
        item[tableStart + 12] = 1
        item.writeUInt64LE(1_700_000_000_123_456, at: tableStart + 16)

        item.writeUInt32LE(UInt32(tag.count), at: tagStart)
        item.replaceSubrange((tagStart + 4)..<(tagStart + 4 + tag.count), with: tag)
        item.writeUInt32LE(UInt32(message.count), at: messageStart)
        item.replaceSubrange((messageStart + 4)..<(messageStart + 4 + message.count), with: message)

        var file = Data()
        file.appendUInt32LE(UInt32(8 + item.count))
        file.appendUInt32LE(UInt32(item.count))
        file.append(item)
        return file
    }

    private func deflate(_ data: Data, windowBits: Int32) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw FixtureError.compression(initialized) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        let chunkSize = chunk.count
        var status = Int32(Z_OK)
        data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self)
            )
            stream.avail_in = uInt(data.count)

            repeat {
                status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return CZlib.deflate(&stream, Z_FINISH)
                }
                let written = chunkSize - Int(stream.avail_out)
                output.append(contentsOf: chunk.prefix(written))
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw FixtureError.compression(status) }
        return output
    }

    private func deflateSyncFlushed(_ data: Data, windowBits: Int32) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw FixtureError.compression(initialized) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        let chunkSize = chunk.count
        var status = Int32(Z_OK)
        data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self)
            )
            stream.avail_in = uInt(data.count)

            repeat {
                status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return CZlib.deflate(&stream, Z_SYNC_FLUSH)
                }
                output.append(contentsOf: chunk.prefix(chunkSize - Int(stream.avail_out)))
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        guard status == Z_OK else { throw FixtureError.compression(status) }
        return output
    }

    private func encryptAES(_ data: Data, credentials: LoganCredentials) throws -> Data {
        try encryptAES(
            data,
            credentials: credentials,
            options: CCOptions(kCCOptionPKCS7Padding)
        )
    }

    private func encryptAESNoPadding(_ data: Data, credentials: LoganCredentials) throws -> Data {
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw FixtureError.invalidAESLength
        }
        return try encryptAES(data, credentials: credentials, options: CCOptions(0))
    }

    private func encryptAES(
        _ data: Data,
        credentials: LoganCredentials,
        options: CCOptions
    ) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0

        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                credentials.key.withUnsafeBytes { keyBuffer in
                    credentials.iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
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
        guard status == kCCSuccess else { throw FixtureError.encryption(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

private enum FixtureError: Error {
    case compression(Int32)
    case encryption(CCCryptorStatus)
    case invalidAESLength
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        replaceSubrange(offset..<(offset + 2), with: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
        ])
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        replaceSubrange(offset..<(offset + 4), with: (0..<4).map {
            UInt8(truncatingIfNeeded: value >> UInt32($0 * 8))
        })
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        replaceSubrange(offset..<(offset + 8), with: (0..<8).map {
            UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
        })
    }
}
