import Foundation

enum DecodeLimits {
    static let maximumInputFileSize: UInt64 = 500 * 1024 * 1024
    static let maximumDecompressedOutputSize = 1024 * 1024 * 1024

    static func validateInputFile(at url: URL, description: String) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw DecodeError.fileOperation("无法读取\(description)大小：\(error.localizedDescription)")
        }
        guard let fileSize = values.fileSize, fileSize >= 0 else {
            throw DecodeError.fileOperation("无法读取\(description)大小")
        }
        guard UInt64(fileSize) <= maximumInputFileSize else {
            throw DecodeError.decodingFailed("\(description)超过 500 MB 大小限制")
        }
    }

    static func validateDecompressedOutputSize(
        currentSize: Int,
        appending additionalSize: Int,
        maximumSize: Int = maximumDecompressedOutputSize
    ) throws {
        let (combinedSize, overflow) = currentSize.addingReportingOverflow(additionalSize)
        guard currentSize >= 0,
              additionalSize >= 0,
              maximumSize >= 0,
              !overflow,
              combinedSize <= maximumSize else {
            throw DecodeError.outputLimitExceeded
        }
    }
}
