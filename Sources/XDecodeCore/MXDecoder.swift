import Foundation

public struct MXDecoder: LogDecoder {
    public let format = LogFormat.mx

    public init() {}

    public func decode(_ data: Data, sourceURL: URL) throws -> DecodedLog {
        guard data.count >= 4 else { throw DecodeError.malformed("MX 文件不足 4 字节") }

        let declaredSize = Int(try data.uint32LE(at: 0))
        let parseLimit = min(max(declaredSize, 4), data.count)
        var cursor = 4
        var lines: [String] = []

        while cursor + 4 <= data.count, cursor <= parseLimit {
            let itemSize = Int(try data.uint32LE(at: cursor))
            let itemStart = cursor + 4
            guard itemSize > 0, itemStart + itemSize <= data.count else { break }

            let item = data.subdata(in: itemStart..<(itemStart + itemSize))
            if let log = try? FlatBufferLog(data: item),
               let line = try? log.renderedLine {
                lines.append(line)
            }
            cursor = itemStart + itemSize
        }

        guard !lines.isEmpty else { throw DecodeError.emptyOutput }
        return .complete(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

private struct FlatBufferLog {
    let data: Data
    let tableStart: Int
    let vtableStart: Int
    let vtableSize: Int

    init(data: Data) throws {
        self.data = data
        let tableStart = Int(try data.uint32LE(at: 0))
        guard tableStart >= 4, tableStart + 4 <= data.count else {
            throw DecodeError.malformed("MX Root Table 偏移无效")
        }
        let vtableOffset = Int(try data.int32LE(at: tableStart))
        let vtableStart = tableStart - vtableOffset
        guard vtableStart >= 0, vtableStart + 2 <= data.count else {
            throw DecodeError.malformed("MX VTable 偏移无效")
        }
        self.tableStart = tableStart
        self.vtableStart = vtableStart
        self.vtableSize = Int(try data.uint16LE(at: vtableStart))
    }

    var renderedLine: String {
        get throws {
            let timestamp = try scalarUInt64(vtableOffset: 16)
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000_000)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
            let time = timestamp == 0 ? "1970-01-01 00:00:00.000000" : formatter.string(from: date)
            let tag = try string(vtableOffset: 6)
            let message = try string(vtableOffset: 8)
            let level = try scalarInt8(vtableOffset: 10)
            let levelText = [0: "D", 1: "I", 2: "W", 3: "E", 4: "F"][Int(level)] ?? "D"
            let tags = tag.isEmpty ? "[]" : "[\(tag.split(separator: ",").map { "'\($0)'" }.joined(separator: ", "))]"
            return "\(time) \(levelText) \(tags) \(message)"
        }
    }

    private func fieldOffset(_ vtableOffset: Int) throws -> Int? {
        guard vtableOffset < vtableSize else { return nil }
        let offset = Int(try data.uint16LE(at: vtableStart + vtableOffset))
        return offset == 0 ? nil : tableStart + offset
    }

    private func string(vtableOffset: Int) throws -> String {
        guard let offset = try fieldOffset(vtableOffset) else { return "" }
        let relativeOffset = Int(try data.uint32LE(at: offset))
        let stringStart = offset + relativeOffset
        let length = Int(try data.uint32LE(at: stringStart))
        let bytes = try data.checkedRange((stringStart + 4)..<(stringStart + 4 + length))
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private func scalarInt8(vtableOffset: Int) throws -> Int8 {
        guard let offset = try fieldOffset(vtableOffset) else { return 0 }
        return try data.int8(at: offset)
    }

    private func scalarUInt64(vtableOffset: Int) throws -> UInt64 {
        guard let offset = try fieldOffset(vtableOffset) else { return 0 }
        return try data.uint64LE(at: offset)
    }
}
