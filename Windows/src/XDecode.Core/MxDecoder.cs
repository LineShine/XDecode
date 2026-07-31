using System.Globalization;
using System.Text;

namespace XDecode.Core;

public sealed class MxDecoder : ILogDecoder
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    public LogFormat Format => LogFormat.Mx;

    public DecodedLog Decode(ReadOnlyMemory<byte> data, string sourcePath)
    {
        var span = data.Span;
        if (span.Length < 4) throw DecodeException.Malformed("MX 文件不足 4 字节");
        var declaredSize = checked((int)span.UInt32LE(0));
        var parseLimit = Math.Min(Math.Max(declaredSize, 4), span.Length);
        var cursor = 4;
        var lines = new List<string>();
        while (cursor + 4 <= span.Length && cursor <= parseLimit)
        {
            var itemSize = checked((int)span.UInt32LE(cursor));
            var itemStart = cursor + 4;
            if (itemSize <= 0 || itemStart > span.Length - itemSize) break;
            try
            {
                var log = new FlatBufferLog(span.Slice(itemStart, itemSize).ToArray());
                lines.Add(log.Render());
            }
            catch (DecodeException) { }
            cursor = itemStart + itemSize;
        }
        if (lines.Count == 0) throw DecodeException.EmptyOutput();
        return DecodedLog.Complete(Encoding.UTF8.GetBytes(string.Join('\n', lines) + "\n"));
    }

    private sealed class FlatBufferLog
    {
        private readonly byte[] _data;
        private readonly int _tableStart;
        private readonly int _vtableStart;
        private readonly int _vtableSize;

        public FlatBufferLog(byte[] data)
        {
            _data = data;
            var span = data.AsSpan();
            _tableStart = checked((int)span.UInt32LE(0));
            if (_tableStart < 4 || _tableStart > span.Length - 4)
                throw DecodeException.Malformed("MX Root Table 偏移无效");
            var vtableOffset = span.Int32LE(_tableStart);
            _vtableStart = checked(_tableStart - vtableOffset);
            if (_vtableStart < 0 || _vtableStart > span.Length - 2)
                throw DecodeException.Malformed("MX VTable 偏移无效");
            _vtableSize = span.UInt16LE(_vtableStart);
        }

        public string Render()
        {
            var timestamp = ScalarUInt64(16);
            var time = timestamp == 0
                ? "1970-01-01 00:00:00.000000"
                : FormatTimestamp(timestamp);
            var tag = String(6);
            var message = String(8);
            var level = ScalarInt8(10) switch { 1 => "I", 2 => "W", 3 => "E", 4 => "F", _ => "D" };
            var tags = tag.Length == 0
                ? "[]"
                : $"[{string.Join(", ", tag.Split(',').Select(value => $"'{value}'"))}]";
            return $"{time} {level} {tags} {message}";
        }

        private static string FormatTimestamp(ulong timestamp)
        {
            if (timestamp > long.MaxValue) throw DecodeException.Malformed("MX 时间戳无效");
            var ticks = checked((long)timestamp * 10);
            var value = DateTimeOffset.UnixEpoch.AddTicks(ticks).ToLocalTime();
            return value.ToString("yyyy-MM-dd HH:mm:ss.ffffff", CultureInfo.InvariantCulture);
        }

        private int? FieldOffset(int vtableOffset)
        {
            if (vtableOffset >= _vtableSize) return null;
            var offset = _data.AsSpan().UInt16LE(_vtableStart + vtableOffset);
            return offset == 0 ? null : checked(_tableStart + offset);
        }

        private string String(int vtableOffset)
        {
            var offset = FieldOffset(vtableOffset);
            if (offset is null) return "";
            var relativeOffset = checked((int)_data.AsSpan().UInt32LE(offset.Value));
            var stringStart = checked(offset.Value + relativeOffset);
            var length = checked((int)_data.AsSpan().UInt32LE(stringStart));
            var bytes = _data.AsSpan().CheckedRange(stringStart + 4, length);
            try { return StrictUtf8.GetString(bytes); }
            catch (DecoderFallbackException) { return Encoding.Latin1.GetString(bytes); }
        }

        private sbyte ScalarInt8(int vtableOffset)
        {
            var offset = FieldOffset(vtableOffset);
            return offset is null ? (sbyte)0 : _data.AsSpan().Int8(offset.Value);
        }

        private ulong ScalarUInt64(int vtableOffset)
        {
            var offset = FieldOffset(vtableOffset);
            return offset is null ? 0 : _data.AsSpan().UInt64LE(offset.Value);
        }
    }
}
