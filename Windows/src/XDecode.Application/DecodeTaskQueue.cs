using System.Threading.Channels;
using XDecode.Core;

namespace XDecode.Application;

public sealed class DecodeTaskQueue : IAsyncDisposable
{
    private readonly Channel<WorkItem> _channel = Channel.CreateUnbounded<WorkItem>(
        new UnboundedChannelOptions { SingleReader = false, SingleWriter = false });
    private readonly Func<DecodeRequest, CancellationToken, Task<DecodeResult>> _processor;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly Task[] _workers;
    private readonly HashSet<string> _activePaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _lock = new();

    public DecodeTaskQueue(
        Func<DecodeRequest, CancellationToken, Task<DecodeResult>> processor,
        int maximumConcurrency = 2)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumConcurrency);
        _processor = processor;
        _workers = Enumerable.Range(0, maximumConcurrency)
            .Select(_ => Task.Run(WorkerAsync)).ToArray();
    }

    public int ScheduledCount
    {
        get { lock (_lock) return _activePaths.Count; }
    }

    public Task<DecodeResult?> EnqueueAsync(
        DecodeRequest request, CancellationToken cancellationToken = default)
    {
        var path = Path.GetFullPath(request.SourcePath);
        lock (_lock)
        {
            if (!_activePaths.Add(path)) return Task.FromResult<DecodeResult?>(null);
        }
        var completion = new TaskCompletionSource<DecodeResult?>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_channel.Writer.TryWrite(new WorkItem(request, path, completion, cancellationToken)))
        {
            lock (_lock) _activePaths.Remove(path);
            completion.TrySetException(new InvalidOperationException("任务队列已关闭"));
        }
        return completion.Task;
    }

    private async Task WorkerAsync()
    {
        try
        {
            await foreach (var item in _channel.Reader.ReadAllAsync(_shutdown.Token).ConfigureAwait(false))
            {
                try
                {
                    using var linked = CancellationTokenSource.CreateLinkedTokenSource(
                        _shutdown.Token, item.CancellationToken);
                    var result = await _processor(item.Request, linked.Token).ConfigureAwait(false);
                    item.Completion.TrySetResult(result);
                }
                catch (OperationCanceledException exception)
                {
                    item.Completion.TrySetCanceled(exception.CancellationToken);
                }
                catch (Exception exception) { item.Completion.TrySetException(exception); }
                finally
                {
                    lock (_lock) _activePaths.Remove(item.Path);
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    public async ValueTask DisposeAsync()
    {
        _channel.Writer.TryComplete();
        _shutdown.Cancel();
        try { await Task.WhenAll(_workers).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        while (_channel.Reader.TryRead(out var item))
        {
            item.Completion.TrySetCanceled(new CancellationToken(canceled: true));
            lock (_lock) _activePaths.Remove(item.Path);
        }
        _shutdown.Dispose();
    }

    private sealed record WorkItem(
        DecodeRequest Request,
        string Path,
        TaskCompletionSource<DecodeResult?> Completion,
        CancellationToken CancellationToken);
}
