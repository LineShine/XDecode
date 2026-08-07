using System.Text.Json;
using System.Text.Json.Serialization;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Math;

namespace XDecode.Core;

[JsonConverter(typeof(CamelCaseJsonStringEnumConverter<LogFormat>))]
public enum LogFormat
{
    Xlog,
    Mx,
    Logan,
    Zip
}

[JsonConverter(typeof(CamelCaseJsonStringEnumConverter<DecodeOrigin>))]
public enum DecodeOrigin
{
    Automatic,
    DragAndDrop,
    FilePicker,
    Explorer,
    OpenWith
}

[JsonConverter(typeof(CamelCaseJsonStringEnumConverter<DecodeState>))]
public enum DecodeState
{
    Completed,
    PartiallyCompleted,
    CompletedWithWarning,
    Skipped,
    Failed
}

public sealed class CamelCaseJsonStringEnumConverter<TEnum>()
    : JsonStringEnumConverter<TEnum>(JsonNamingPolicy.CamelCase)
    where TEnum : struct, Enum;

public sealed record DecodeRequest(
    Guid Id,
    string SourcePath,
    LogFormat Format,
    DecodeOrigin Origin,
    DateTimeOffset RequestedAt)
{
    public DecodeRequest(string sourcePath, DecodeOrigin origin, LogFormat? format = null)
        : this(Guid.NewGuid(), Path.GetFullPath(sourcePath), format ?? LogFormats.Detect(sourcePath), origin, DateTimeOffset.UtcNow) { }
}

public sealed record DecodeResult(
    Guid Id,
    DecodeRequest Request,
    DecodeState State,
    string? OutputPath,
    string Message,
    bool SourceDeleted,
    DateTimeOffset FinishedAt)
{
    public DecodeResult(DecodeRequest request, DecodeState state, string? outputPath, string message, bool sourceDeleted)
        : this(Guid.NewGuid(), request, state, outputPath, message, sourceDeleted, DateTimeOffset.UtcNow) { }
}

public sealed record DecodedLog(byte[] Data, bool IsComplete, string? Diagnostic = null)
{
    public static DecodedLog Complete(byte[] data, string? diagnostic = null) => new(data, true, diagnostic);
    public static DecodedLog Partial(byte[] data, string diagnostic) => new(data, false, diagnostic);
}

public sealed class XlogCredentials
{
    public byte[] PrivateKey { get; }

    public XlogCredentials(ReadOnlySpan<byte> privateKey)
    {
        if (privateKey.Length != 32)
            throw DecodeException.InvalidCredentials("Xlog secp256k1 私钥必须是 32 字节（64 位 Hex）");
        var domain = SecNamedCurves.GetByName("secp256k1");
        var scalar = new BigInteger(1, privateKey.ToArray());
        if (scalar.SignValue <= 0 || scalar.CompareTo(domain.N) >= 0)
            throw DecodeException.InvalidCredentials("Xlog secp256k1 私钥不是有效标量");
        PrivateKey = privateKey.ToArray();
    }

    public XlogCredentials(string privateKeyHex)
    {
        var normalized = string.Concat(privateKeyHex.Where(c => !char.IsWhiteSpace(c)));
        if (normalized.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) normalized = normalized[2..];
        if (normalized.Length != 64)
            throw DecodeException.InvalidCredentials("Xlog secp256k1 私钥必须是 64 位 Hex");
        byte[] bytes;
        try { bytes = Convert.FromHexString(normalized); }
        catch (FormatException) { throw DecodeException.InvalidCredentials("Xlog secp256k1 私钥必须是 64 位 Hex"); }
        var validated = new XlogCredentials(bytes);
        PrivateKey = validated.PrivateKey;
    }
}

public sealed record LoganCredentials
{
    public byte[] Key { get; }
    public byte[] IV { get; }

    [JsonConstructor]
    public LoganCredentials(byte[] key, byte[] iv)
    {
        if (key.Length < 16) throw DecodeException.InvalidCredentials("Logan AES Key 至少需要 16 字节");
        if (iv.Length < 16) throw DecodeException.InvalidCredentials("Logan AES IV 至少需要 16 字节");
        Key = key[..16];
        IV = iv[..16];
    }

    public LoganCredentials(string key, string iv)
        : this(System.Text.Encoding.UTF8.GetBytes(key), System.Text.Encoding.UTF8.GetBytes(iv)) { }
}

public interface ILogDecoder
{
    LogFormat Format { get; }
    DecodedLog Decode(ReadOnlyMemory<byte> data, string sourcePath);
}

public delegate ValueTask<ILogDecoder> DecoderResolver(DecodeRequest request, CancellationToken cancellationToken);

public static class LogFormats
{
    public static LogFormat Detect(string path)
    {
        var extension = Path.GetExtension(path);
        if (extension.Equals(".xlog", StringComparison.OrdinalIgnoreCase)) return LogFormat.Xlog;
        if (extension.Equals(".mx", StringComparison.OrdinalIgnoreCase)) return LogFormat.Mx;
        if (extension.Equals(".logan", StringComparison.OrdinalIgnoreCase)) return LogFormat.Logan;
        if (extension.Equals(".zip", StringComparison.OrdinalIgnoreCase)) return LogFormat.Zip;
        if (System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(path), @"^\d{4}-\d{2}-\d{2}$"))
            return LogFormat.Logan;
        throw DecodeException.UnsupportedFormat(extension.Length == 0 ? "无扩展名" : extension.TrimStart('.'));
    }
}

public enum DecodeErrorKind
{
    UnsupportedFormat, Malformed, InvalidCredentials, MissingCredentials, DecodingFailed,
    DecompressionFailed, OutputLimitExceeded, DecryptionFailed, EmptyOutput, FileOperation
}

public sealed class DecodeException(DecodeErrorKind kind, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public DecodeErrorKind Kind { get; } = kind;

    public static DecodeException UnsupportedFormat(string value) =>
        new(DecodeErrorKind.UnsupportedFormat, $"不支持的日志格式：{value}");
    public static DecodeException Malformed(string value) =>
        new(DecodeErrorKind.Malformed, $"日志内容损坏：{value}");
    public static DecodeException InvalidCredentials(string value) =>
        new(DecodeErrorKind.InvalidCredentials, value);
    public static DecodeException MissingCredentials(LogFormat format) =>
        new(DecodeErrorKind.MissingCredentials, format switch
        {
            LogFormat.Xlog => "没有匹配且可读取的 Xlog secp256k1 私钥方案",
            LogFormat.Logan => "没有匹配的 Logan Key/IV 方案",
            LogFormat.Mx => "MX 不需要密钥方案",
            _ => "ZIP 容器本身不使用日志密钥"
        });
    public static DecodeException DecodingFailed(string value) =>
        new(DecodeErrorKind.DecodingFailed, value);
    public static DecodeException DecompressionFailed(string value, Exception? inner = null) =>
        new(DecodeErrorKind.DecompressionFailed, $"解压失败：{value}", inner);
    public static DecodeException OutputLimitExceeded() =>
        new(DecodeErrorKind.OutputLimitExceeded, "解压输出超过单任务 1 GiB 大小限制");
    public static DecodeException DecryptionFailed(string value, Exception? inner = null) =>
        new(DecodeErrorKind.DecryptionFailed, $"解密失败：{value}", inner);
    public static DecodeException EmptyOutput() => new(DecodeErrorKind.EmptyOutput, "解密结果为空");
    public static DecodeException FileOperation(string value, Exception? inner = null) =>
        new(DecodeErrorKind.FileOperation, $"文件操作失败：{value}", inner);
}
