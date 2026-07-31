namespace XDecode.Application;

public sealed class FileStabilityGate
{
    public const int RequiredStableCheckCount = 2;
    private readonly HashSet<string> _pendingPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _lock = new();

    public async Task<bool> WaitUntilStableAsync(
        string path,
        int checks = RequiredStableCheckCount,
        TimeSpan? interval = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        path = Path.GetFullPath(path);
        lock (_lock)
        {
            if (!_pendingPaths.Add(path)) return false;
        }
        try
        {
            var sampleInterval = interval ?? TimeSpan.FromSeconds(1);
            var deadline = DateTimeOffset.UtcNow + (timeout ?? TimeSpan.FromSeconds(60));
            Snapshot? previous = null;
            var stableCount = 0;
            while (DateTimeOffset.UtcNow < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var current = Snapshot.Create(path);
                if (current is null) return false;
                if (current == previous)
                {
                    stableCount++;
                    if (stableCount >= checks) return true;
                }
                else
                {
                    stableCount = 0;
                    previous = current;
                }
                var remaining = deadline - DateTimeOffset.UtcNow;
                await Task.Delay(remaining < sampleInterval ? remaining : sampleInterval, cancellationToken)
                    .ConfigureAwait(false);
            }
            return false;
        }
        catch (OperationCanceledException) { return false; }
        finally
        {
            lock (_lock) _pendingPaths.Remove(path);
        }
    }

    private sealed record Snapshot(long Size, DateTime LastWriteUtc)
    {
        public static Snapshot? Create(string path)
        {
            try
            {
                var info = new FileInfo(path);
                return info.Exists ? new(info.Length, info.LastWriteTimeUtc) : null;
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }
    }
}
