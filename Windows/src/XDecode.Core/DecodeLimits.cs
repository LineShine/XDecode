namespace XDecode.Core;

public static class DecodeLimits
{
    public const long MaximumInputFileSize = 500L * 1024 * 1024;
    public const int MaximumDecompressedOutputSize = 1024 * 1024 * 1024;

    public static void ValidateInputFile(string path, string description)
    {
        FileInfo info;
        try { info = new FileInfo(path); }
        catch (Exception exception) { throw DecodeException.FileOperation($"无法读取{description}大小：{exception.Message}", exception); }
        if (!info.Exists) throw DecodeException.FileOperation($"无法读取{description}大小");
        if (info.Length > MaximumInputFileSize)
            throw DecodeException.DecodingFailed($"{description}超过 500 MB 大小限制");
    }

    public static void ValidateOutputSize(long currentSize, long additionalSize, long maximumSize = MaximumDecompressedOutputSize)
    {
        if (currentSize < 0 || additionalSize < 0 || maximumSize < 0 ||
            currentSize > maximumSize - additionalSize)
            throw DecodeException.OutputLimitExceeded();
    }
}
