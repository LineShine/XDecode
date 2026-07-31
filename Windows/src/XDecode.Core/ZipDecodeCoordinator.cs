using System.IO.Compression;
using System.IO.Hashing;

namespace XDecode.Core;

public delegate ValueTask<LogFormat?> ArchiveEntryFormatResolver(string path, CancellationToken cancellationToken);

public interface IZipOutputPublicationTracker
{
    ValueTask PreparePublicationAsync(string stagingDirectory, string destinationDirectory, CancellationToken cancellationToken);
    ValueTask CancelPublicationAsync(string stagingDirectory, CancellationToken cancellationToken);
}

public sealed class ZipDecodeCoordinator(
    DecoderResolver decoderResolver,
    ArchiveEntryFormatResolver? entryFormatResolver = null,
    IZipOutputPublicationTracker? publicationTracker = null)
{
    private const int MaximumArchiveEntryCount = 1_000;
    private const int MaximumLogCount = 100;
    private const long MaximumEntrySize = DecodeLimits.MaximumInputFileSize;
    private const long MaximumTotalSize = 1024L * 1024 * 1024;
    private readonly ArchiveEntryFormatResolver _entryFormatResolver =
        entryFormatResolver ?? DefaultEntryFormatResolver;

    public async Task<DecodeResult> DecodeAsync(
        DecodeRequest request,
        CancellationToken cancellationToken = default)
    {
        var sourcePath = Path.GetFullPath(request.SourcePath);
        string? stagingDirectory = null;
        try
        {
            if (request.Format != LogFormat.Zip) throw DecodeException.UnsupportedFormat(request.Format.ToString());
            if (!File.Exists(sourcePath)) throw DecodeException.FileOperation("源 ZIP 不存在");
            DecodeLimits.ValidateInputFile(sourcePath, "源 ZIP");

            using var file = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var archive = new ZipArchive(file, ZipArchiveMode.Read, leaveOpen: false);
            var items = await InspectEntriesAsync(archive, sourcePath, cancellationToken).ConfigureAwait(false);
            var logCount = items.Count(value => value.Format is not null);
            if (logCount == 0)
            {
                return new DecodeResult(
                    request, DecodeState.Skipped, null,
                    "ZIP 中没有符合当前规则的 Xlog、MX 或 Logan 日志；未生成输出目录，源 ZIP 已保留",
                    false);
            }
            if (logCount > MaximumLogCount)
                throw DecodeException.DecodingFailed($"ZIP 中日志数量超过 {MaximumLogCount} 个");

            var parent = Path.GetDirectoryName(sourcePath)
                ?? throw DecodeException.FileOperation("无法确定源 ZIP 目录");
            stagingDirectory = Path.Combine(parent, $".xdecode-zip-{Guid.NewGuid():N}.tmp");
            Directory.CreateDirectory(stagingDirectory);
            File.SetAttributes(stagingDirectory, FileAttributes.Directory | FileAttributes.Hidden);

            foreach (var item in items.Where(value => value.Format is null))
                await ExtractPreservedItemAsync(item, stagingDirectory, cancellationToken).ConfigureAwait(false);

            var decodedCount = 0;
            long decodedOutputSize = 0;
            var failedLogNames = new List<string>();
            foreach (var item in items.Where(value => value.Format is not null))
            {
                var virtualPath = Path.Combine(parent, item.RelativePath.Replace('/', Path.DirectorySeparatorChar));
                var payload = await ExtractDataAsync(item, cancellationToken).ConfigureAwait(false);
                var entryRequest = new DecodeRequest(
                    Guid.NewGuid(), virtualPath, item.Format!.Value, request.Origin, request.RequestedAt);
                string? decodedOutputPath = null;
                try
                {
                    var decoder = await decoderResolver(entryRequest, cancellationToken).ConfigureAwait(false);
                    var decoded = decoder.Decode(payload, virtualPath);
                    if (!decoded.IsComplete)
                        throw DecodeException.DecodingFailed(decoded.Diagnostic ?? "日志未完整解密");
                    if (decoded.Data.Length == 0) throw DecodeException.EmptyOutput();
                    DecodeLimits.ValidateOutputSize(decodedOutputSize, decoded.Data.Length);
                    decodedOutputPath = UniqueDecodedOutput(item.RelativePath, stagingDirectory);
                    await WriteExclusiveAsync(decoded.Data, decodedOutputPath, cancellationToken).ConfigureAwait(false);
                    decodedOutputSize += decoded.Data.Length;
                    decodedCount++;
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    TryDelete(decodedOutputPath);
                    var originalPath = Path.Combine(
                        stagingDirectory, item.RelativePath.Replace('/', Path.DirectorySeparatorChar));
                    await WriteExclusiveAsync(payload, originalPath, cancellationToken).ConfigureAwait(false);
                    failedLogNames.Add(Path.GetFileName(item.RelativePath));
                }
            }

            var outputDirectory = await MoveToUniqueOutputDirectoryAsync(
                stagingDirectory, sourcePath, cancellationToken).ConfigureAwait(false);
            stagingDirectory = null;
            var failedCount = failedLogNames.Count;
            if (failedCount == 0)
            {
                return new DecodeResult(
                    request, DecodeState.Completed, outputDirectory,
                    $"ZIP 批量解密成功：{decodedCount}/{logCount} 个日志已生成 .log；源 ZIP 已保留", false);
            }
            if (decodedCount == 0)
            {
                return new DecodeResult(
                    request, DecodeState.Failed, outputDirectory,
                    $"ZIP 批量解密失败：0/{logCount} 个日志成功；全部原始日志已保留在输出目录；源 ZIP 已保留", false);
            }
            var names = string.Join('、', failedLogNames.Take(5));
            var remaining = failedCount > 5 ? $"等 {failedCount} 个文件" : "";
            return new DecodeResult(
                request, DecodeState.PartiallyCompleted, outputDirectory,
                $"ZIP 批量部分成功：成功 {decodedCount} 个，失败 {failedCount} 个；{names}{remaining} 已保留原始日志；源 ZIP 已保留",
                false);
        }
        catch (Exception exception)
        {
            if (stagingDirectory is not null)
            {
                if (publicationTracker is not null)
                    await publicationTracker.CancelPublicationAsync(stagingDirectory, CancellationToken.None).ConfigureAwait(false);
                TryDeleteDirectory(stagingDirectory);
            }
            return new DecodeResult(
                request, DecodeState.Failed, null,
                $"{exception.Message}；未生成输出目录，源 ZIP 已保留", false);
        }
    }

    private async Task<IReadOnlyList<ArchiveItem>> InspectEntriesAsync(
        ZipArchive archive, string sourcePath, CancellationToken cancellationToken)
    {
        if (archive.Entries.Count > MaximumArchiveEntryCount)
            throw DecodeException.DecodingFailed($"ZIP 条目总数超过 {MaximumArchiveEntryCount} 个");
        var items = new List<ArchiveItem>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long totalSize = 0;
        foreach (var entry in archive.Entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var relativePath = ZipPathValidator.ValidateRelativePath(entry.FullName);
            if (!seen.Add(relativePath))
                throw DecodeException.DecodingFailed($"ZIP 包含重复路径：{relativePath}");
            if (ZipPathValidator.IsMetadataPath(relativePath)) continue;
            var kind = EntryKind(entry);
            if (kind == ArchiveItemKind.Special)
                throw DecodeException.DecodingFailed($"ZIP 包含符号链接或特殊条目：{relativePath}");
            if (kind == ArchiveItemKind.File)
            {
                if (entry.Length > MaximumEntrySize)
                    throw DecodeException.DecodingFailed($"ZIP 条目超过 500 MB：{relativePath}");
                DecodeLimits.ValidateOutputSize(totalSize, entry.Length, MaximumTotalSize);
                totalSize += entry.Length;
            }
            LogFormat? format = null;
            if (kind == ArchiveItemKind.File)
            {
                var virtualPath = Path.Combine(
                    Path.GetDirectoryName(sourcePath) ?? "",
                    relativePath.Replace('/', Path.DirectorySeparatorChar));
                var detected = await _entryFormatResolver(virtualPath, cancellationToken).ConfigureAwait(false);
                if (detected is LogFormat.Xlog or LogFormat.Mx or LogFormat.Logan) format = detected;
            }
            items.Add(new ArchiveItem(entry, relativePath, kind, format));
        }
        return items;
    }

    private static ArchiveItemKind EntryKind(ZipArchiveEntry entry)
    {
        var unixType = (entry.ExternalAttributes >> 16) & 0xf000;
        if (unixType != 0 && unixType is not 0x8000 and not 0x4000) return ArchiveItemKind.Special;
        if ((entry.ExternalAttributes & 0x400) != 0) return ArchiveItemKind.Special;
        var directory = entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\') ||
            (entry.ExternalAttributes & (int)FileAttributes.Directory) != 0 || unixType == 0x4000;
        return directory ? ArchiveItemKind.Directory : ArchiveItemKind.File;
    }

    private static async Task ExtractPreservedItemAsync(
        ArchiveItem item, string stagingDirectory, CancellationToken cancellationToken)
    {
        var destination = Path.Combine(
            stagingDirectory, item.RelativePath.Replace('/', Path.DirectorySeparatorChar));
        if (item.Kind == ArchiveItemKind.Directory)
        {
            Directory.CreateDirectory(destination);
            return;
        }
        var payload = await ExtractDataAsync(item, cancellationToken).ConfigureAwait(false);
        await WriteExclusiveAsync(payload, destination, cancellationToken).ConfigureAwait(false);
    }

    private static async Task<byte[]> ExtractDataAsync(ArchiveItem item, CancellationToken cancellationToken)
    {
        await using var input = item.Entry.Open();
        using var output = new MemoryStream((int)Math.Min(item.Entry.Length, 1024 * 1024));
        var crc = new Crc32();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            DecodeLimits.ValidateOutputSize(output.Length, count, MaximumEntrySize);
            crc.Append(buffer.AsSpan(0, count));
            output.Write(buffer, 0, count);
        }
        if (output.Length != item.Entry.Length)
            throw DecodeException.DecodingFailed($"{item.RelativePath} 解压后的大小不完整");
        if (crc.GetCurrentHashAsUInt32() != item.Entry.Crc32)
            throw DecodeException.DecodingFailed($"{item.RelativePath} ZIP CRC 校验失败");
        return output.ToArray();
    }

    private static string UniqueDecodedOutput(string relativePath, string stagingDirectory)
    {
        var relativeParent = Path.GetDirectoryName(relativePath.Replace('/', Path.DirectorySeparatorChar));
        var baseName = Path.GetFileNameWithoutExtension(relativePath);
        for (var index = 0; ; index++)
        {
            var suffix = index == 0 ? "" : $"-{index}";
            var fileName = $"{baseName}{suffix}.log";
            var candidate = relativeParent is null
                ? Path.Combine(stagingDirectory, fileName)
                : Path.Combine(stagingDirectory, relativeParent, fileName);
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
    }

    private async Task<string> MoveToUniqueOutputDirectoryAsync(
        string stagingDirectory, string sourcePath, CancellationToken cancellationToken)
    {
        var parent = Path.GetDirectoryName(sourcePath) ?? "";
        var baseName = Path.GetFileNameWithoutExtension(sourcePath);
        for (var index = 0; ; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var suffix = index == 0 ? "" : $"-{index}";
            var candidate = Path.Combine(parent, $"{baseName}{suffix}");
            if (publicationTracker is not null)
                await publicationTracker.PreparePublicationAsync(stagingDirectory, candidate, cancellationToken).ConfigureAwait(false);
            if (WindowsFilePublication.TryMoveExclusive(stagingDirectory, candidate)) return candidate;
        }
    }

    private static async Task WriteExclusiveAsync(
        ReadOnlyMemory<byte> data, string path, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? "");
        await using var stream = new FileStream(
            path, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            64 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough);
        await stream.WriteAsync(data, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        stream.Flush(flushToDisk: true);
    }

    private static ValueTask<LogFormat?> DefaultEntryFormatResolver(
        string path, CancellationToken cancellationToken)
    {
        try { return ValueTask.FromResult<LogFormat?>(LogFormats.Detect(path)); }
        catch { return ValueTask.FromResult<LogFormat?>(null); }
    }

    private static void TryDelete(string? path)
    {
        try { if (path is not null && File.Exists(path)) File.Delete(path); }
        catch { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
        catch { }
    }

    private enum ArchiveItemKind { File, Directory, Special }
    private sealed record ArchiveItem(
        ZipArchiveEntry Entry, string RelativePath, ArchiveItemKind Kind, LogFormat? Format);
}
