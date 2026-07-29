import CZlib
import Foundation
import SwiftZSTD
import zstdlib

enum CompressionUtilities {
    static func inflateRaw(
        _ data: Data,
        maximumOutputSize: Int = DecodeLimits.maximumDecompressedOutputSize
    ) throws -> Data {
        try inflate(
            data,
            windowBits: -MAX_WBITS,
            allowsSyncFlushTermination: true,
            maximumOutputSize: maximumOutputSize
        )
    }

    static func gunzip(
        _ data: Data,
        maximumOutputSize: Int = DecodeLimits.maximumDecompressedOutputSize
    ) throws -> Data {
        try inflate(
            data,
            windowBits: MAX_WBITS + 16,
            allowsSyncFlushTermination: false,
            maximumOutputSize: maximumOutputSize
        )
    }

    static func inflateZlibOrGzip(
        _ data: Data,
        maximumOutputSize: Int = DecodeLimits.maximumDecompressedOutputSize
    ) throws -> Data {
        try inflate(
            data,
            windowBits: MAX_WBITS + 32,
            flush: Z_SYNC_FLUSH,
            allowsSyncFlushTermination: false,
            maximumOutputSize: maximumOutputSize
        )
    }

    static func inflateUnfinishedZlibOrGzip(
        _ data: Data,
        maximumOutputSize: Int = DecodeLimits.maximumDecompressedOutputSize
    ) throws -> Data {
        try inflate(
            data,
            windowBits: MAX_WBITS + 32,
            flush: Z_SYNC_FLUSH,
            allowsSyncFlushTermination: false,
            allowsInputExhaustionTermination: true,
            maximumOutputSize: maximumOutputSize
        )
    }

    static func zstd(
        _ data: Data,
        maximumOutputSize: Int = DecodeLimits.maximumDecompressedOutputSize
    ) throws -> Data {
        do {
            guard !data.isEmpty else {
                throw DecodeError.decompressionFailed("zstd 输入为空")
            }
            let declaredSize = data.withUnsafeBytes { buffer in
                ZSTD_getFrameContentSize(buffer.baseAddress, data.count)
            }
            guard declaredSize != UInt64.max - 1 else {
                throw DecodeError.decompressionFailed("zstd 帧无效")
            }
            guard declaredSize != UInt64.max else {
                throw DecodeError.decompressionFailed("zstd 帧未声明解压大小")
            }
            guard declaredSize <= UInt64(Int.max) else {
                throw DecodeError.outputLimitExceeded
            }
            try DecodeLimits.validateDecompressedOutputSize(
                currentSize: 0,
                appending: Int(declaredSize),
                maximumSize: maximumOutputSize
            )
            let output = try ZSTDProcessor().decompressFrame(data)
            try DecodeLimits.validateDecompressedOutputSize(
                currentSize: 0,
                appending: output.count,
                maximumSize: maximumOutputSize
            )
            return output
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.decompressionFailed("zstd: \(error.localizedDescription)")
        }
    }

    private static func inflate(
        _ data: Data,
        windowBits: Int32,
        flush: Int32 = Z_NO_FLUSH,
        allowsSyncFlushTermination: Bool,
        allowsInputExhaustionTermination: Bool = false,
        maximumOutputSize: Int
    ) throws -> Data {
        guard !data.isEmpty else { throw DecodeError.decompressionFailed("输入为空") }

        let syncFlushMarker = [UInt8](arrayLiteral: 0x00, 0x00, 0xFF, 0xFF)
        let hasSyncFlushTermination = allowsSyncFlushTermination
            && data.count >= syncFlushMarker.count
            && data.suffix(syncFlushMarker.count).elementsEqual(syncFlushMarker)

        var stream = z_stream()
        let initializeStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initializeStatus == Z_OK else {
            throw DecodeError.decompressionFailed("zlib 初始化失败：\(initializeStatus)")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        return try data.withUnsafeBytes { inputBuffer in
            guard let baseAddress = inputBuffer.baseAddress else {
                throw DecodeError.decompressionFailed("无法读取输入")
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)

            while true {
                let status = chunk.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return CZlib.inflate(&stream, flush)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    try DecodeLimits.validateDecompressedOutputSize(
                        currentSize: output.count,
                        appending: produced,
                        maximumSize: maximumOutputSize
                    )
                    output.append(contentsOf: chunk[0..<produced])
                }

                if status == Z_STREAM_END {
                    return output
                }

                let inputConsumed = stream.avail_in == 0
                let outputDrained = stream.avail_out > 0
                if hasSyncFlushTermination,
                   inputConsumed,
                   outputDrained,
                   !output.isEmpty,
                   status == Z_OK || status == Z_BUF_ERROR {
                    return output
                }

                if allowsInputExhaustionTermination,
                   inputConsumed,
                   outputDrained,
                   !output.isEmpty,
                   status == Z_OK || status == Z_BUF_ERROR {
                    return output
                }

                guard status == Z_OK else {
                    let message = stream.msg.map { String(cString: $0) } ?? "状态码 \(status)"
                    throw DecodeError.decompressionFailed(message)
                }

                if inputConsumed, outputDrained {
                    throw DecodeError.decompressionFailed("deflate 数据流缺少结束标记")
                }
            }
        }
    }
}
