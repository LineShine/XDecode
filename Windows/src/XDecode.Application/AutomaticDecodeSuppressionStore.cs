using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using XDecode.Core;

namespace XDecode.Application;

public sealed class AutomaticDecodeSuppressionStore : IZipOutputPublicationTracker
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };
    private readonly string _filePath;
    private readonly TimeSpan _retention;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private List<Batch> _batches;

    public AutomaticDecodeSuppressionStore(string localStateDirectory, TimeSpan? retention = null)
    {
        Directory.CreateDirectory(localStateDirectory);
        _filePath = Path.Combine(localStateDirectory, "automatic-decode-suppressions.v1.json");
        _retention = retention ?? TimeSpan.FromDays(7);
        _batches = Load();
    }

    public async ValueTask PreparePublicationAsync(
        string stagingDirectory,
        string destinationDirectory,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            RemoveExpired();
            var stagingPath = Normalize(stagingDirectory);
            var destinationRoot = Normalize(destinationDirectory);
            var entries = Directory.EnumerateFiles(stagingDirectory, "*", SearchOption.AllDirectories)
                .Select(file =>
                {
                    var relative = Path.GetRelativePath(stagingDirectory, file);
                    return new Entry(
                        Normalize(Path.Combine(destinationDirectory, relative)),
                        FileIdentity.Read(file));
                }).ToList();
            _batches.RemoveAll(value => value.StagingPath.Equals(stagingPath, StringComparison.OrdinalIgnoreCase));
            _batches.Add(new(stagingPath, destinationRoot, DateTimeOffset.UtcNow, entries));
            await PersistAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async ValueTask CancelPublicationAsync(
        string stagingDirectory,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var path = Normalize(stagingDirectory);
            _batches.RemoveAll(value => value.StagingPath.Equals(path, StringComparison.OrdinalIgnoreCase));
            await PersistAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task<bool> ConsumeIfRegisteredAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var changed = RemoveExpired();
            FileIdentity identity;
            try { identity = FileIdentity.Read(path); }
            catch (IOException)
            {
                if (changed) await PersistAsync(cancellationToken).ConfigureAwait(false);
                return false;
            }
            var normalized = Normalize(path);
            var matched = false;
            for (var batchIndex = _batches.Count - 1; batchIndex >= 0; batchIndex--)
            {
                var entries = _batches[batchIndex].Entries;
                for (var entryIndex = entries.Count - 1; entryIndex >= 0; entryIndex--)
                {
                    var entry = entries[entryIndex];
                    if (!entry.DestinationPath.Equals(normalized, StringComparison.OrdinalIgnoreCase)) continue;
                    entries.RemoveAt(entryIndex);
                    changed = true;
                    matched |= entry.Identity == identity;
                }
                if (entries.Count == 0) _batches.RemoveAt(batchIndex);
            }
            if (changed) await PersistAsync(cancellationToken).ConfigureAwait(false);
            return matched;
        }
        finally { _gate.Release(); }
    }

    private bool RemoveExpired()
    {
        var count = _batches.Count;
        var cutoff = DateTimeOffset.UtcNow - _retention;
        _batches.RemoveAll(value => value.CreatedAt < cutoff);
        return count != _batches.Count;
    }

    private List<Batch> Load()
    {
        try
        {
            return File.Exists(_filePath)
                ? JsonSerializer.Deserialize<List<Batch>>(File.ReadAllBytes(_filePath), JsonOptions) ?? []
                : [];
        }
        catch (IOException) { return []; }
        catch (JsonException) { return []; }
    }

    private Task PersistAsync(CancellationToken cancellationToken) =>
        AtomicJson.WriteAsync(_filePath, _batches, JsonOptions, cancellationToken);

    private static string Normalize(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);

    public sealed record Batch(
        string StagingPath,
        string DestinationRootPath,
        DateTimeOffset CreatedAt,
        List<Entry> Entries);
    public sealed record Entry(string DestinationPath, FileIdentity Identity);
    public sealed record FileIdentity(uint VolumeSerialNumber, ulong FileIndex)
    {
        public static FileIdentity Read(string path)
        {
            using SafeFileHandle handle = File.OpenHandle(
                path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, FileOptions.None);
            if (!GetFileInformationByHandle(handle, out var information))
                throw new IOException(Marshal.GetLastPInvokeError().ToString(System.Globalization.CultureInfo.InvariantCulture));
            return new(
                information.VolumeSerialNumber,
                ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle fileHandle, out ByHandleFileInformation fileInformation);
}
