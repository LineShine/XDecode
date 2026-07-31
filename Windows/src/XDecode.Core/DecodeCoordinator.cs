namespace XDecode.Core;

public sealed class DecodeCoordinator(DecoderResolver decoderResolver)
{
    public async Task<DecodeResult> DecodeAsync(
        DecodeRequest request,
        CancellationToken cancellationToken = default)
    {
        var sourcePath = Path.GetFullPath(request.SourcePath);
        var directory = Path.GetDirectoryName(sourcePath)
            ?? throw DecodeException.FileOperation("无法确定源文件目录");
        var temporaryPath = Path.Combine(directory, $".xdecode-{Guid.NewGuid():N}.tmp");
        string? outputPath = null;
        try
        {
            if (!File.Exists(sourcePath)) throw DecodeException.FileOperation("源文件不存在");
            DecodeLimits.ValidateInputFile(sourcePath, "源文件");
            var input = await File.ReadAllBytesAsync(sourcePath, cancellationToken).ConfigureAwait(false);
            var decoder = await decoderResolver(request, cancellationToken).ConfigureAwait(false);
            var decoded = decoder.Decode(input, sourcePath);
            if (!decoded.IsComplete)
            {
                return new DecodeResult(
                    request, DecodeState.Failed, null,
                    $"解密失败：{decoded.Diagnostic ?? "日志未完整解密"}；未生成 .log，源文件已保留",
                    false);
            }
            if (decoded.Data.Length == 0) throw DecodeException.EmptyOutput();
            DecodeLimits.ValidateOutputSize(0, decoded.Data.Length);

            await using (var stream = new FileStream(
                temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                64 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                WindowsFilePublication.MarkHidden(temporaryPath);
                await stream.WriteAsync(decoded.Data, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            outputPath = MoveToUniqueOutput(temporaryPath, sourcePath);

            try
            {
                File.Delete(sourcePath);
                return new DecodeResult(
                    request, DecodeState.Completed, outputPath,
                    decoded.Diagnostic is null
                        ? "解密完成，源文件已永久删除"
                        : $"{decoded.Diagnostic}；源文件已永久删除",
                    true);
            }
            catch (Exception exception)
            {
                return new DecodeResult(
                    request, DecodeState.CompletedWithWarning, outputPath,
                    decoded.Diagnostic is null
                        ? $"解密完成，但源文件删除失败：{exception.Message}"
                        : $"{decoded.Diagnostic}；源文件删除失败：{exception.Message}",
                    false);
            }
        }
        catch (Exception exception)
        {
            TryDelete(temporaryPath);
            return new DecodeResult(
                request, DecodeState.Failed, outputPath,
                exception.Message, false);
        }
    }

    public static string OutputPath(string sourcePath, int index = 0)
    {
        var directory = Path.GetDirectoryName(sourcePath) ?? "";
        var baseName = Path.GetFileNameWithoutExtension(sourcePath);
        var suffix = index == 0 ? "" : $"-{index}";
        return Path.Combine(directory, $"{baseName}{suffix}.log");
    }

    private static string MoveToUniqueOutput(string temporaryPath, string sourcePath)
    {
        for (var index = 0; ; index++)
        {
            var candidate = OutputPath(sourcePath, index);
            if (WindowsFilePublication.TryMoveExclusive(temporaryPath, candidate)) return candidate;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }
}

public static class StandardDecoderResolver
{
    public static DecoderResolver Create(
        Func<string, CancellationToken, ValueTask<IReadOnlyList<XlogCredentials>>> xlogCredentials,
        Func<string, CancellationToken, ValueTask<IReadOnlyList<LoganCredentials>>> loganCredentials) =>
        async (request, cancellationToken) => request.Format switch
        {
            LogFormat.Xlog => new XlogDecoder(await xlogCredentials(request.SourcePath, cancellationToken)),
            LogFormat.Mx => new MxDecoder(),
            LogFormat.Logan => new LoganDecoder(await loganCredentials(request.SourcePath, cancellationToken)),
            _ => throw DecodeException.UnsupportedFormat("ZIP 容器需要通过批量解密流程处理")
        };
}
