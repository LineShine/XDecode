namespace XDecode.Application;

public sealed class FolderMonitorService : IDisposable
{
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly HashSet<string> _knownFiles = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _monitoredFolders = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private CancellationTokenSource? _lifetime;

    public event Func<string, Task>? NewFile;

    public async Task StartAsync(
        IEnumerable<string> folders,
        CancellationToken cancellationToken = default)
    {
        Stop();
        var normalized = folders
            .Select(Path.GetFullPath)
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (normalized.Length == 0) return;

        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        foreach (var folder in normalized)
        {
            _monitoredFolders.Add(folder.TrimEnd(Path.DirectorySeparatorChar));
            foreach (var file in EnumerateRegularFiles(folder)) _knownFiles.Add(file);
            var watcher = new FileSystemWatcher(folder)
            {
                IncludeSubdirectories = true,
                InternalBufferSize = 64 * 1024,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName |
                               NotifyFilters.Size | NotifyFilters.LastWrite,
                EnableRaisingEvents = false
            };
            watcher.Created += OnCreated;
            watcher.Renamed += OnRenamed;
            watcher.Deleted += OnDeleted;
            watcher.Error += OnError;
            _watchers.Add(watcher);
            watcher.EnableRaisingEvents = true;
        }
        await RecoveryScanAsync(_lifetime.Token).ConfigureAwait(false);
    }

    public void Stop()
    {
        _lifetime?.Cancel();
        _lifetime?.Dispose();
        _lifetime = null;
        foreach (var watcher in _watchers)
        {
            watcher.EnableRaisingEvents = false;
            watcher.Created -= OnCreated;
            watcher.Renamed -= OnRenamed;
            watcher.Deleted -= OnDeleted;
            watcher.Error -= OnError;
            watcher.Dispose();
        }
        _watchers.Clear();
        _knownFiles.Clear();
        _monitoredFolders.Clear();
    }

    private void OnCreated(object sender, FileSystemEventArgs arguments) =>
        QueuePath(arguments.FullPath);

    private void OnRenamed(object sender, RenamedEventArgs arguments)
    {
        RemoveKnownPaths(arguments.OldFullPath);
        QueuePath(arguments.FullPath);
    }

    private void OnDeleted(object sender, FileSystemEventArgs arguments) =>
        RemoveKnownPaths(arguments.FullPath);

    private void OnError(object sender, ErrorEventArgs arguments)
    {
        if (_lifetime is { } lifetime) _ = RecoveryScanAsync(lifetime.Token);
    }

    private void QueuePath(string path)
    {
        if (_lifetime is not { } lifetime || lifetime.IsCancellationRequested) return;
        _ = HandlePathAsync(path, lifetime.Token);
    }

    private async Task HandlePathAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken).ConfigureAwait(false);
            if (IsHiddenPath(path)) return;
            if (File.Exists(path))
            {
                var normalized = Path.GetFullPath(path);
                lock (_knownFiles)
                {
                    if (!_knownFiles.Add(normalized)) return;
                }
                if (NewFile is { } handler) await handler(normalized).ConfigureAwait(false);
                return;
            }
            if (Directory.Exists(path))
            {
                foreach (var file in EnumerateRegularFiles(path))
                {
                    bool added;
                    lock (_knownFiles) added = _knownFiles.Add(file);
                    if (added && NewFile is { } handler) await handler(file).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private async Task RecoveryScanAsync(CancellationToken cancellationToken)
    {
        if (!await _scanGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return;
        try
        {
            var current = _monitoredFolders
                .SelectMany(EnumerateRegularFiles)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            List<string> added;
            lock (_knownFiles)
            {
                added = current.Except(_knownFiles, StringComparer.OrdinalIgnoreCase).Order().ToList();
                _knownFiles.Clear();
                _knownFiles.UnionWith(current);
            }
            foreach (var file in added)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (NewFile is { } handler) await handler(file).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
        finally { _scanGate.Release(); }
    }

    private void RemoveKnownPaths(string path)
    {
        var normalized = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        var prefix = normalized + Path.DirectorySeparatorChar;
        lock (_knownFiles)
        {
            _knownFiles.RemoveWhere(value =>
                value.Equals(normalized, StringComparison.OrdinalIgnoreCase) ||
                value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
        }
    }

    private bool IsHiddenPath(string path)
    {
        var normalized = Path.GetFullPath(path);
        var root = _monitoredFolders.FirstOrDefault(folder =>
            normalized.Equals(folder, StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
        if (root is null) return true;
        var relative = Path.GetRelativePath(root, normalized);
        if (relative.Split(Path.DirectorySeparatorChar).Any(value => value.StartsWith('.'))) return true;
        try { return (File.GetAttributes(normalized) & FileAttributes.Hidden) != 0; }
        catch { return false; }
    }

    private static IEnumerable<string> EnumerateRegularFiles(string folder)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint
        };
        try
        {
            return Directory.EnumerateFiles(folder, "*", options).Select(Path.GetFullPath).ToArray();
        }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
    }

    public void Dispose()
    {
        Stop();
        _scanGate.Dispose();
    }
}
