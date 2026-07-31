using System.Security.Cryptography;
using System.Text;

namespace XDecode.Core;

public sealed class LoganDecoder : ILogDecoder
{
    private static readonly LoganCredentials Unkeyed = new(new byte[16], new byte[16]);
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly LoganCredentials[] _credentials;
    public LogFormat Format => LogFormat.Logan;

    public LoganDecoder(LoganCredentials credentials) : this([credentials]) { }
    public LoganDecoder(IEnumerable<LoganCredentials> credentials) => _credentials = credentials.ToArray();

    public DecodedLog Decode(ReadOnlyMemory<byte> data, string sourcePath)
    {
        var candidates = new[] { Unkeyed }.Concat(_credentials.Where(value => !CredentialsEqual(value, Unkeyed)));
        Exception? lastError = null;
        foreach (var candidate in candidates)
        {
            try { return DecodeWithCredentials(data.Span, candidate); }
            catch (DecodeException exception) when (exception.Kind == DecodeErrorKind.OutputLimitExceeded) { throw; }
            catch (Exception exception) { lastError = exception; }
        }
        if (_credentials.Length == 0) throw DecodeException.MissingCredentials(LogFormat.Logan);
        if (_credentials.Length == 1 && lastError is not null) throw lastError;
        throw DecodeException.DecryptionFailed($"{_credentials.Length} 个匹配的 Logan Key/IV 均无法解密，密钥不匹配或日志损坏");
    }

    private static DecodedLog DecodeWithCredentials(ReadOnlySpan<byte> data, LoganCredentials credentials)
    {
        if (data.IsEmpty) throw DecodeException.Malformed("Logan 文件为空");
        using var output = new MemoryStream();
        var cursor = 0;
        var frames = 0;
        while (cursor < data.Length)
        {
            var marker = data.UInt8(cursor++);
            if (marker != 0x01) throw DecodeException.Malformed($"Logan 帧标记无效：0x{marker:x}");
            var encryptedSize = checked((int)data.UInt32BE(cursor));
            cursor += 4;
            if (encryptedSize is <= 0 or >= 10_000_000)
                throw DecodeException.Malformed($"Logan 数据块长度无效：{encryptedSize}");
            var encrypted = data.CheckedRange(cursor, encryptedSize);
            cursor += encryptedSize;
            var unfinishedFinalFrame = cursor == data.Length;
            var decoded = DecodeFrame(
                encrypted, credentials, unfinishedFinalFrame,
                checked(DecodeLimits.MaximumDecompressedOutputSize - (int)output.Length));
            DecodeLimits.ValidateOutputSize(output.Length, decoded.Length);
            output.Write(decoded);
            frames++;
            if (cursor < data.Length && data.UInt8(cursor++) != 0)
                throw DecodeException.Malformed("Logan 帧分隔符无效");
        }
        if (frames == 0 || output.Length == 0) throw DecodeException.EmptyOutput();
        return DecodedLog.Complete(output.ToArray());
    }

    private static byte[] DecodeFrame(
        ReadOnlySpan<byte> encrypted,
        LoganCredentials credentials,
        bool allowsUnfinishedStream,
        int maximumOutputSize)
    {
        foreach (var padding in new[] { PaddingMode.PKCS7, PaddingMode.None })
        {
            try
            {
                var decrypted = DecryptAesCbc(encrypted, credentials, padding);
                return DecodeCompressedFrame(
                    decrypted, allowsUnfinishedStream && padding == PaddingMode.None, maximumOutputSize);
            }
            catch (DecodeException exception) when (exception.Kind == DecodeErrorKind.OutputLimitExceeded) { throw; }
            catch { }
        }
        throw DecodeException.DecryptionFailed("Logan Key/IV 不匹配，或 AES/压缩数据损坏");
    }

    private static byte[] DecodeCompressedFrame(byte[] decrypted, bool allowsUnfinishedStream, int maximumOutputSize)
    {
        try
        {
            var output = CompressionUtilities.InflateZlibOrGzip(decrypted, maximumOutputSize);
            ValidateUtf8(output, "Logan 解密内容不是有效的 UTF-8 文本");
            return output;
        }
        catch (DecodeException exception) when (
            allowsUnfinishedStream && exception.Kind != DecodeErrorKind.OutputLimitExceeded)
        {
            var recovered = CompressionUtilities.InflateUnfinishedZlibOrGzip(decrypted, maximumOutputSize);
            var lastNewline = Array.LastIndexOf(recovered, (byte)'\n');
            if (lastNewline < 0)
                throw DecodeException.DecompressionFailed("Logan 未完成末帧没有完整日志行");
            var completeLines = recovered[..(lastNewline + 1)];
            ValidateUtf8(completeLines, "Logan 未完成末帧不是有效的 UTF-8 文本");
            return completeLines;
        }
    }

    private static byte[] DecryptAesCbc(
        ReadOnlySpan<byte> data, LoganCredentials credentials, PaddingMode padding)
    {
        if (data.Length % 16 != 0)
            throw DecodeException.DecryptionFailed("AES-CBC 数据长度不是 16 的倍数");
        try
        {
            using var aes = Aes.Create();
            aes.Mode = CipherMode.CBC;
            aes.Padding = padding;
            aes.Key = credentials.Key;
            aes.IV = credentials.IV;
            using var decryptor = aes.CreateDecryptor();
            return decryptor.TransformFinalBlock(data.ToArray(), 0, data.Length);
        }
        catch (CryptographicException exception)
        {
            throw DecodeException.DecryptionFailed(exception.Message, exception);
        }
    }

    private static void ValidateUtf8(byte[] data, string message)
    {
        if (data.Length == 0) throw DecodeException.EmptyOutput();
        try { _ = StrictUtf8.GetString(data); }
        catch (DecoderFallbackException) { throw DecodeException.DecodingFailed(message); }
    }

    private static bool CredentialsEqual(LoganCredentials left, LoganCredentials right) =>
        left.Key.AsSpan().SequenceEqual(right.Key) && left.IV.AsSpan().SequenceEqual(right.IV);
}
