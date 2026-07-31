using System.Runtime.InteropServices;
using ZstdSharp;

namespace XDecode.Core;

internal static class CompressionUtilities
{
    private const int ZNoFlush = 0;
    private const int ZSyncFlush = 2;
    private const int ZOk = 0;
    private const int ZStreamEnd = 1;
    private const int ZBufError = -5;
    private const int MaxWindowBits = 15;

    public static byte[] InflateRaw(ReadOnlySpan<byte> data, int maximumOutputSize) =>
        Inflate(data, -MaxWindowBits, ZNoFlush, true, false, maximumOutputSize);

    public static byte[] InflateZlibOrGzip(ReadOnlySpan<byte> data, int maximumOutputSize) =>
        Inflate(data, MaxWindowBits + 32, ZSyncFlush, false, false, maximumOutputSize);

    public static byte[] InflateUnfinishedZlibOrGzip(ReadOnlySpan<byte> data, int maximumOutputSize) =>
        Inflate(data, MaxWindowBits + 32, ZSyncFlush, false, true, maximumOutputSize);

    public static byte[] Zstd(ReadOnlySpan<byte> data, int maximumOutputSize)
    {
        if (data.IsEmpty) throw DecodeException.DecompressionFailed("zstd 输入为空");
        var declaredSize = ReadZstdFrameContentSize(data);
        DecodeLimits.ValidateOutputSize(0, declaredSize, maximumOutputSize);

        try
        {
            using var input = new MemoryStream(data.ToArray(), writable: false);
            using var decompressor = new DecompressionStream(input);
            using var output = new MemoryStream((int)Math.Min(declaredSize, 1024 * 1024));
            CopyBounded(decompressor, output, maximumOutputSize);
            if (output.Length != declaredSize)
                throw DecodeException.DecompressionFailed("zstd 解压后的大小与帧声明不一致");
            return output.ToArray();
        }
        catch (DecodeException) { throw; }
        catch (Exception exception)
        {
            throw DecodeException.DecompressionFailed($"zstd: {exception.Message}", exception);
        }
    }

    private static unsafe byte[] Inflate(
        ReadOnlySpan<byte> data,
        int windowBits,
        int flush,
        bool allowsSyncFlushTermination,
        bool allowsInputExhaustionTermination,
        int maximumOutputSize)
    {
        if (data.IsEmpty) throw DecodeException.DecompressionFailed("输入为空");
        var hasSyncFlushTermination = allowsSyncFlushTermination &&
            data.EndsWith(stackalloc byte[] { 0x00, 0x00, 0xff, 0xff });
        var stream = new ZStream();
        var initializeStatus = ZlibNative.InflateInit2(
            ref stream, windowBits, ZlibNative.Version(), Marshal.SizeOf<ZStream>());
        if (initializeStatus != ZOk)
            throw DecodeException.DecompressionFailed($"zlib 初始化失败：{initializeStatus}");

        try
        {
            fixed (byte* input = data)
            {
                stream.NextIn = input;
                stream.AvailIn = checked((uint)data.Length);
                using var output = new MemoryStream();
                var chunk = new byte[64 * 1024];
                while (true)
                {
                    int status;
                    int produced;
                    fixed (byte* outputPointer = chunk)
                    {
                        stream.NextOut = outputPointer;
                        stream.AvailOut = checked((uint)chunk.Length);
                        status = ZlibNative.Inflate(ref stream, flush);
                        produced = chunk.Length - checked((int)stream.AvailOut);
                    }

                    if (produced > 0)
                    {
                        DecodeLimits.ValidateOutputSize(output.Length, produced, maximumOutputSize);
                        output.Write(chunk, 0, produced);
                    }
                    if (status == ZStreamEnd) return output.ToArray();

                    var inputConsumed = stream.AvailIn == 0;
                    var outputDrained = stream.AvailOut > 0;
                    var acceptedStatus = status is ZOk or ZBufError;
                    if ((hasSyncFlushTermination || allowsInputExhaustionTermination) &&
                        inputConsumed && outputDrained && output.Length > 0 && acceptedStatus)
                        return output.ToArray();

                    if (status != ZOk)
                    {
                        var message = stream.Message == null
                            ? $"状态码 {status}"
                            : Marshal.PtrToStringAnsi((nint)stream.Message) ?? $"状态码 {status}";
                        throw DecodeException.DecompressionFailed(message);
                    }
                    if (inputConsumed && outputDrained)
                        throw DecodeException.DecompressionFailed("deflate 数据流缺少结束标记");
                }
            }
        }
        finally
        {
            _ = ZlibNative.InflateEnd(ref stream);
        }
    }

    private static long ReadZstdFrameContentSize(ReadOnlySpan<byte> data)
    {
        if (data.Length < 6 || !data[..4].SequenceEqual(stackalloc byte[] { 0x28, 0xb5, 0x2f, 0xfd }))
            throw DecodeException.DecompressionFailed("zstd 帧无效");
        var descriptor = data[4];
        if ((descriptor & 0x18) != 0)
            throw DecodeException.DecompressionFailed("zstd 帧头保留位无效");

        var singleSegment = (descriptor & 0x20) != 0;
        var dictionaryFlag = descriptor & 0x03;
        var contentSizeFlag = descriptor >> 6;
        var cursor = 5 + (singleSegment ? 0 : 1);
        cursor += dictionaryFlag switch { 0 => 0, 1 => 1, 2 => 2, _ => 4 };
        var contentSizeLength = contentSizeFlag switch
        {
            0 when singleSegment => 1,
            0 => 0,
            1 => 2,
            2 => 4,
            _ => 8
        };
        if (contentSizeLength == 0)
            throw DecodeException.DecompressionFailed("zstd 帧未声明解压大小");
        if (cursor > data.Length - contentSizeLength)
            throw DecodeException.DecompressionFailed("zstd 帧头不完整");

        ulong value = 0;
        for (var index = 0; index < contentSizeLength; index++)
            value |= (ulong)data[cursor + index] << (8 * index);
        if (contentSizeLength == 2) value += 256;
        if (value > int.MaxValue) throw DecodeException.OutputLimitExceeded();
        return (long)value;
    }

    private static void CopyBounded(Stream input, Stream output, int maximumOutputSize)
    {
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = input.Read(buffer);
            if (count == 0) break;
            DecodeLimits.ValidateOutputSize(output.Length, count, maximumOutputSize);
            output.Write(buffer, 0, count);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct ZStream
    {
        public byte* NextIn;
        public uint AvailIn;
        public uint TotalIn;
        public byte* NextOut;
        public uint AvailOut;
        public uint TotalOut;
        public byte* Message;
        public nint State;
        public nint Zalloc;
        public nint Zfree;
        public nint Opaque;
        public int DataType;
        public uint Adler;
        public uint Reserved;
    }

    private static class ZlibNative
    {
        [DllImport("zlib1", EntryPoint = "zlibVersion", CallingConvention = CallingConvention.Cdecl)]
        public static extern nint Version();

        [DllImport("zlib1", EntryPoint = "inflateInit2_", CallingConvention = CallingConvention.Cdecl)]
        public static extern int InflateInit2(ref ZStream stream, int windowBits, nint version, int streamSize);

        [DllImport("zlib1", EntryPoint = "inflate", CallingConvention = CallingConvention.Cdecl)]
        public static extern int Inflate(ref ZStream stream, int flush);

        [DllImport("zlib1", EntryPoint = "inflateEnd", CallingConvention = CallingConvention.Cdecl)]
        public static extern int InflateEnd(ref ZStream stream);
    }
}
