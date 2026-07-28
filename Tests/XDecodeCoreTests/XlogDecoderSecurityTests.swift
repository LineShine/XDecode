import CZlib
import Foundation
import P256K
import Testing
@testable import XDecodeCore

@Suite("Xlog secure decoding")
struct XlogDecoderSecurityTests {
    @Test("Encrypted 0x07 frame tries a wrong key before the matching key")
    func triesAllMatchingKeys() throws {
        let expected = Data("encrypted xlog fixture\n".utf8)
        let fixture = try encryptedFrame(expected)
        let wrong = try XlogCredentials(privateKey: scalar(3))
        let matching = try XlogCredentials(privateKey: serverPrivateKey)

        let result = try XlogDecoder(credentials: [wrong, matching]).decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/encrypted.xlog")
        )

        #expect(result.isComplete)
        #expect(result.data == expected)
        #expect(result.diagnostic?.contains("成功 1 帧，失败 0 帧") == true)
    }

    @Test("Encrypted frame without a key fails with explicit frame counts")
    func missingKeyFailsWithoutOutput() throws {
        let fixture = try encryptedFrame(Data("secret\n".utf8))

        do {
            _ = try XlogDecoder().decode(
                fixture,
                sourceURL: URL(fileURLWithPath: "/tmp/missing-key.xlog")
            )
            Issue.record("Expected encrypted Xlog without credentials to fail")
        } catch {
            #expect(error.localizedDescription.contains("成功 0 帧，失败 1 帧"))
            #expect(error.localizedDescription.contains("缺少匹配"))
        }
    }

    @Test("Encrypted frame with only wrong keys reports a mismatch")
    func wrongKeysFailWithoutOutput() throws {
        let fixture = try encryptedFrame(Data("secret\n".utf8))
        let wrong = try XlogCredentials(privateKey: scalar(4))

        do {
            _ = try XlogDecoder(credentials: [wrong]).decode(
                fixture,
                sourceURL: URL(fileURLWithPath: "/tmp/wrong-key.xlog")
            )
            Issue.record("Expected all incorrect Xlog credentials to fail")
        } catch {
            #expect(error.localizedDescription.contains("成功 0 帧，失败 1 帧"))
            #expect(error.localizedDescription.contains("私钥不匹配"))
        }
    }

    @Test("A missing key produces clean partial output from successful plaintext frames")
    func partialOutputContainsOnlySuccessfulFrames() throws {
        let plain = Data("plaintext metadata\n".utf8)
        var fixture = xlogFrame(magic: 0x08, sequence: 1, payload: plain)
        fixture.append(try encryptedFrame(Data("encrypted payload\n".utf8), sequence: 2))

        let result = try XlogDecoder().decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/partial.xlog")
        )

        #expect(!result.isComplete)
        #expect(result.data == plain)
        #expect(!String(decoding: result.data, as: UTF8.self).contains("[F]"))
        #expect(result.diagnostic?.contains("成功 1 帧，失败 1 帧") == true)
        #expect(result.diagnostic?.contains("缺少匹配私钥") == true)
    }

    @Test("Sequence gaps mark otherwise valid plaintext output as partial")
    func sequenceGapIsPartial() throws {
        var fixture = xlogFrame(magic: 0x08, sequence: 1, payload: Data("one\n".utf8))
        fixture.append(xlogFrame(magic: 0x08, sequence: 3, payload: Data("three\n".utf8)))

        let result = try XlogDecoder().decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/gap.xlog")
        )

        #expect(!result.isComplete)
        #expect(result.data == Data("one\nthree\n".utf8))
        #expect(result.diagnostic?.contains("序号缺失") == true)
    }

    @Test("Damaged bytes are skipped without inserting failure markers")
    func damagedSectionIsPartial() throws {
        var fixture = xlogFrame(magic: 0x08, sequence: 1, payload: Data("first\n".utf8))
        fixture.append(contentsOf: [0xFF, 0xFE, 0xFD])
        fixture.append(xlogFrame(magic: 0x08, sequence: 2, payload: Data("second\n".utf8)))

        let result = try XlogDecoder().decode(
            fixture,
            sourceURL: URL(fileURLWithPath: "/tmp/damaged.xlog")
        )

        #expect(!result.isComplete)
        #expect(result.data == Data("first\nsecond\n".utf8))
        #expect(!String(decoding: result.data, as: UTF8.self).contains("[F]"))
        #expect(result.diagnostic?.contains("跳过 1 段损坏数据（3 字节）") == true)
    }

    private var serverPrivateKey: Data { scalar(1) }

    private func encryptedFrame(_ plaintext: Data, sequence: UInt16 = 1) throws -> Data {
        let server = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: serverPrivateKey,
            format: .uncompressed
        )
        let client = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: scalar(2),
            format: .uncompressed
        )
        let sharedSecret = client.sharedSecretFromKeyAgreement(
            with: server.publicKey,
            format: .uncompressed
        )
        let sharedPoint = sharedSecret.withUnsafeBytes { Data($0) }
        let teaKey = sharedPoint.subdata(in: 1..<17)
        let compressed = try deflateRaw(plaintext)
        let encrypted = TEAFixture.encrypt(compressed, key: teaKey)
        let publicKey = client.publicKey.uncompressedRepresentation.dropFirst()
        return xlogFrame(
            magic: 0x07,
            sequence: sequence,
            payload: encrypted,
            publicKey: Data(publicKey)
        )
    }

    private func xlogFrame(
        magic: UInt8,
        sequence: UInt16,
        payload: Data,
        publicKey: Data = Data(repeating: 0, count: 64)
    ) -> Data {
        var data = Data([magic])
        data.appendUInt16LE(sequence)
        data.append(contentsOf: [0, 0])
        data.appendUInt32LE(UInt32(payload.count))
        data.append(publicKey)
        data.append(payload)
        data.append(0)
        return data
    }

    private func scalar(_ value: UInt8) -> Data {
        var data = Data(repeating: 0, count: 32)
        data[data.count - 1] = value
        return data
    }

    private func deflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw XlogFixtureError.compression(initialized) }
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
                output.append(contentsOf: chunk.prefix(chunkSize - Int(stream.avail_out)))
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw XlogFixtureError.compression(status) }
        return output
    }
}

private enum XlogFixtureError: Error {
    case compression(Int32)
}

private enum TEAFixture {
    static func encrypt(_ data: Data, key: Data) -> Data {
        let completeLength = data.count / 8 * 8
        let keyWords = (0..<4).map { word(key, offset: $0 * 4) }
        var output = Data(capacity: data.count)

        var offset = 0
        while offset < completeLength {
            var v0 = word(data, offset: offset)
            var v1 = word(data, offset: offset + 4)
            let delta: UInt32 = 0x9E37_79B9
            var sum: UInt32 = 0

            for _ in 0..<16 {
                sum = sum &+ delta
                v0 = v0 &+ (((v1 &<< 4) &+ keyWords[0]) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ keyWords[1]))
                v1 = v1 &+ (((v0 &<< 4) &+ keyWords[2]) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ keyWords[3]))
            }
            appendLittleEndian(v0, to: &output)
            appendLittleEndian(v1, to: &output)
            offset += 8
        }
        if completeLength < data.count { output.append(data.suffix(from: completeLength)) }
        return output
    }

    private static func word(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
    }
}
