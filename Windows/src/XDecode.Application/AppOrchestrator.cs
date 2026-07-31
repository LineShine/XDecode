using XDecode.Core;

namespace XDecode.Application;

public sealed class AppOrchestrator : IAsyncDisposable
{
    private readonly SettingsStore _settings;
    private readonly HistoryStore _history;
    private readonly AutomaticDecodeSuppressionStore _suppressions;
    private readonly FileStabilityGate _stability = new();
    private readonly FolderMonitorService _monitor = new();
    private readonly DecodeCoordinator _fileCoordinator;
    private readonly ZipDecodeCoordinator _zipCoordinator;
    private readonly DecodeTaskQueue _queue;

    public event Action<DecodeResult>? ResultCompleted;

    public AppOrchestrator(SettingsStore settings, string localStateDirectory)
    {
        _settings = settings;
        _history = new HistoryStore(localStateDirectory);
        _suppressions = new AutomaticDecodeSuppressionStore(localStateDirectory);
        var resolver = StandardDecoderResolver.Create(
            (path, _) => ValueTask.FromResult(_settings.XlogCredentialsFor(path)),
            (path, _) => ValueTask.FromResult(_settings.LoganCredentialsFor(path)));
        _fileCoordinator = new DecodeCoordinator(resolver);
        _zipCoordinator = new ZipDecodeCoordinator(
            resolver,
            (path, _) => ValueTask.FromResult(_settings.LogFormatFor(path, includeZip: false)),
            _suppressions);
        _queue = new DecodeTaskQueue(ProcessAsync, maximumConcurrency: 2);
        _monitor.NewFile += HandleAutomaticFileAsync;
    }

    public Task<IReadOnlyList<DecodeResult>> LoadHistoryAsync(
        CancellationToken cancellationToken = default) =>
        _history.LoadAsync(cancellationToken);

    public Task ClearHistoryAsync(CancellationToken cancellationToken = default) =>
        _history.ClearAsync(cancellationToken);

    public async Task StartMonitoringAsync(CancellationToken cancellationToken = default)
    {
        if (!_settings.Current.AutomaticEnabled)
        {
            _monitor.Stop();
            return;
        }
        await _monitor.StartAsync(_settings.MonitoredFolders, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<DecodeResult>> EnqueueAsync(
        IEnumerable<string> paths,
        DecodeOrigin origin,
        CancellationToken cancellationToken = default)
    {
        var tasks = new List<Task<DecodeResult?>>();
        foreach (var path in paths)
        {
            if (!File.Exists(path)) continue;
            var format = _settings.LogFormatFor(path);
            if (format is null) continue;
            tasks.Add(_queue.EnqueueAsync(
                new DecodeRequest(path, origin, format), cancellationToken));
        }
        return (await Task.WhenAll(tasks).ConfigureAwait(false)).OfType<DecodeResult>().ToArray();
    }

    private async Task HandleAutomaticFileAsync(string path)
    {
        if (await _suppressions.ConsumeIfRegisteredAsync(path).ConfigureAwait(false)) return;
        var format = _settings.LogFormatFor(path);
        if (format is null) return;
        if (!await _stability.WaitUntilStableAsync(path).ConfigureAwait(false)) return;
        await _queue.EnqueueAsync(new DecodeRequest(path, DecodeOrigin.Automatic, format)).ConfigureAwait(false);
    }

    private async Task<DecodeResult> ProcessAsync(
        DecodeRequest request,
        CancellationToken cancellationToken)
    {
        var result = request.Format == LogFormat.Zip
            ? await _zipCoordinator.DecodeAsync(request, cancellationToken).ConfigureAwait(false)
            : await _fileCoordinator.DecodeAsync(request, cancellationToken).ConfigureAwait(false);
        if (result.State != DecodeState.Skipped)
        {
            await _history.AppendAsync(result, cancellationToken).ConfigureAwait(false);
            ResultCompleted?.Invoke(result);
        }
        return result;
    }

    public async ValueTask DisposeAsync()
    {
        _monitor.NewFile -= HandleAutomaticFileAsync;
        _monitor.Dispose();
        await _queue.DisposeAsync().ConfigureAwait(false);
        await _history.DisposeAsync().ConfigureAwait(false);
    }
}
