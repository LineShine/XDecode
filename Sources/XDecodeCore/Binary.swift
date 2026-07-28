import Foundation

extension Data {
    func checkedRange(_ range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw DecodeError.malformed("读取越界 \(range.lowerBound)..<\(range.upperBound)，文件长度 \(count)")
        }
        return subdata(in: range)
    }

    func uint8(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < count else {
            throw DecodeError.malformed("读取 UInt8 越界：\(offset)")
        }
        return self[index(startIndex, offsetBy: offset)]
    }

    func int8(at offset: Int) throws -> Int8 {
        Int8(bitPattern: try uint8(at: offset))
    }

    func uint16LE(at offset: Int) throws -> UInt16 {
        let bytes = try checkedRange(offset..<(offset + 2))
        return bytes.enumerated().reduce(0) { $0 | (UInt16($1.element) << UInt16($1.offset * 8)) }
    }

    func uint16BE(at offset: Int) throws -> UInt16 {
        let bytes = try checkedRange(offset..<(offset + 2))
        return bytes.reduce(0) { ($0 << 8) | UInt16($1) }
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        let bytes = try checkedRange(offset..<(offset + 4))
        return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    func int32LE(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try uint32LE(at: offset))
    }

    func uint32BE(at offset: Int) throws -> UInt32 {
        let bytes = try checkedRange(offset..<(offset + 4))
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64LE(at offset: Int) throws -> UInt64 {
        let bytes = try checkedRange(offset..<(offset + 8))
        return bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
    }
}

extension Data {
    init?(hexadecimal string: String) {
        guard string.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
