using System.Buffers.Binary;

namespace XDecode.Core;

internal static class Binary
{
    public static ReadOnlySpan<byte> CheckedRange(this ReadOnlySpan<byte> data, int offset, int length)
    {
        if (offset < 0 || length < 0 || offset > data.Length - length)
            throw DecodeException.Malformed($"读取越界 {offset}..<{offset + length}，文件长度 {data.Length}");
        return data.Slice(offset, length);
    }

    public static byte UInt8(this ReadOnlySpan<byte> data, int offset) => data.CheckedRange(offset, 1)[0];
    public static sbyte Int8(this ReadOnlySpan<byte> data, int offset) => unchecked((sbyte)data.UInt8(offset));
    public static ushort UInt16LE(this ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadUInt16LittleEndian(data.CheckedRange(offset, 2));
    public static uint UInt32LE(this ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadUInt32LittleEndian(data.CheckedRange(offset, 4));
    public static int Int32LE(this ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadInt32LittleEndian(data.CheckedRange(offset, 4));
    public static uint UInt32BE(this ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadUInt32BigEndian(data.CheckedRange(offset, 4));
    public static ulong UInt64LE(this ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadUInt64LittleEndian(data.CheckedRange(offset, 8));
}
