import CZlib
import Foundation
import Testing
@testable import XDecodeCore

@Suite("Xlog sync-flush decoding")
struct XlogSyncFlushTests {
    @Test("A plaintext 0x09 frame accepts a complete Z_SYNC_FLUSH raw-deflate stream")
    func decodesSyncFlushedFrame() throws {
        let expected = Data((0..<500).map { "sync-flush line \($0)\n" }.joined().utf8)
        let compressed = try deflateSyncFlushed(expected)
        #expect(compressed.suffix(4).elementsEqual([UInt8](arrayLiteral: 0x00, 0x00, 0xFF, 0xFF)))

        let result = try XlogDecoder().decode(
            xlogFrame(magic: 0x09, payload: compressed),
            sourceURL: URL(fileURLWithPath: "/tmp/sync-flush.xlog")
        )

        #expect(result.isComplete)
        #expect(result.data == expected)
    }

    @Test("A raw-deflate stream without a final or sync-flush marker is rejected")
    func rejectsTruncatedRawDeflate() throws {
        var compressed = try deflateSyncFlushed(Data("truncated fixture\n".utf8))
        compressed.removeLast()

        #expect(throws: (any Error).self) {
            try CompressionUtilities.inflateRaw(compressed)
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

    private func deflateSyncFlushed(_ data: Data) throws -> Data {
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
        guard initialized == Z_OK else { throw SyncFlushFixtureError.compression(initialized) }
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

        guard status == Z_OK else { throw SyncFlushFixtureError.compression(status) }
        return output
    }
}

private enum SyncFlushFixtureError: Error {
    case compression(Int32)
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
