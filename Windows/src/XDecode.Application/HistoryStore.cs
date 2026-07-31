using System.Text.Json;
using XDecode.Core;

namespace XDecode.Application;

public sealed class HistoryStore : IAsyncDisposable
{
    public const int MaximumInMemoryCount = 30;
    public const int MaximumPersistedCount = 200;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };
    private readonly string _filePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly TimeSpan _retention;
    private List<DecodeResult>? _values;
    private CancellationTokenSource? _debounce;
    private CancellationTokenSource? _maximumDelay;

    public HistoryStore(string localStateDirectory, TimeSpan? retention = null)
    {
        Directory.CreateDirectory(localStateDirectory);
        _filePath = Path.Combine(localStateDirectory, "history.v1.json");
        _retention = retention ?? TimeSpan.FromDays(30);
    }

    public async Task<IReadOnlyList<DecodeResult>> LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(cancellationToken).ConfigureAwait(false);
            return _values!.Take(MaximumInMemoryCount).ToArray();
        }
        finally { _gate.Release(); }
    }

    public async Task AppendAsync(DecodeResult result, CancellationToken cancellationToken = default)
    {
        if (result.State == DecodeState.Skipped) return;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(cancellationToken).ConfigureAwait(false);
            _values!.RemoveAll(value => value.Id == result.Id);
            _values.Insert(0, result);
            RetainValues();
            SchedulePersistence();
        }
        finally { _gate.Release(); }
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            CancelPersistence();
            _values = [];
            if (File.Exists(_filePath)) File.Delete(_filePath);
        }
        finally { _gate.Release(); }
    }

    public async Task FlushAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await PersistLockedAsync(cancellationToken).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }

    private async Task EnsureLoadedAsync(CancellationToken cancellationToken)
    {
        if (_values is not null) return;
        try
        {
            await using var stream = File.OpenRead(_filePath);
            _values = await JsonSerializer.DeserializeAsync<List<DecodeResult>>(
                stream, JsonOptions, cancellationToken).ConfigureAwait(false) ?? [];
        }
        catch (FileNotFoundException) { _values = []; }
        catch (JsonException) { _values = []; }
        catch (IOException) { _values = []; }
        RetainValues();
    }

    private void RetainValues()
    {
        var cutoff = DateTimeOffset.UtcNow - _retention;
        _values = _values!
            .Where(value => value.State != DecodeState.Skipped && value.FinishedAt >= cutoff)
            .OrderByDescending(value => value.FinishedAt)
            .Take(MaximumPersistedCount).ToList();
    }

    private void SchedulePersistence()
    {
        _debounce?.Cancel();
        _debounce?.Dispose();
        _debounce = new CancellationTokenSource();
        _ = PersistAfterAsync(TimeSpan.FromSeconds(1), _debounce.Token);
        if (_maximumDelay is not null) return;
        _maximumDelay = new CancellationTokenSource();
        _ = PersistAfterAsync(TimeSpan.FromSeconds(5), _maximumDelay.Token);
    }

    private async Task PersistAfterAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            await FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
    }

    private async Task PersistLockedAsync(CancellationToken cancellationToken)
    {
        CancelPersistence();
        if (_values is null) return;
        await AtomicJson.WriteAsync(_filePath, _values, JsonOptions, cancellationToken).ConfigureAwait(false);
    }

    private void CancelPersistence()
    {
        _debounce?.Cancel();
        _debounce?.Dispose();
        _debounce = null;
        _maximumDelay?.Cancel();
        _maximumDelay?.Dispose();
        _maximumDelay = null;
    }

    public async ValueTask DisposeAsync()
    {
        await FlushAsync().ConfigureAwait(false);
        _gate.Dispose();
    }
}
