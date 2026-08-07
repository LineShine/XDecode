using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed record InstanceActivation(
    bool? ShowWindow,
    DecodeOrigin Origin,
    string[] Paths);

public sealed class SingleInstanceCoordinator : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly Mutex _mutex;
    private readonly string _pipeName;
    private CancellationTokenSource? _shutdown;
    private Task? _listener;

    public bool IsPrimary { get; }
    public event Action<InstanceActivation>? ActivationReceived;

    public SingleInstanceCoordinator(string? scope = null)
    {
        var identity = scope ?? WindowsIdentity.GetCurrent().User?.Value
            ?? $"{Environment.UserDomainName}\\{Environment.UserName}";
        var suffix = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..16];
        _pipeName = $"LineShine.XDecode.{suffix}";
        _mutex = new Mutex(
            initiallyOwned: false,
            $"Local\\LineShine.XDecode.{suffix}",
            out var createdNew);
        IsPrimary = createdNew;
    }

    public void StartListening()
    {
        if (!IsPrimary || _listener is not null) return;
        _shutdown = new CancellationTokenSource();
        _listener = Task.Run(() => ListenAsync(_shutdown.Token));
    }

    public async Task<bool> ForwardAsync(
        InstanceActivation activation,
        CancellationToken cancellationToken = default)
    {
        var payload = JsonSerializer.Serialize(activation, JsonOptions);
        for (var attempt = 0; attempt < 20; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await using var client = new NamedPipeClientStream(
                    ".",
                    _pipeName,
                    PipeDirection.Out,
                    PipeOptions.Asynchronous);
                await client.ConnectAsync(500, cancellationToken).ConfigureAwait(false);
                await using var writer = new StreamWriter(client, Encoding.UTF8, leaveOpen: true);
                await writer.WriteLineAsync(payload.AsMemory(), cancellationToken).ConfigureAwait(false);
                await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
                return true;
            }
            catch (TimeoutException)
            {
                if (attempt == 19) return false;
                await Task.Delay(150, cancellationToken).ConfigureAwait(false);
            }
            catch (IOException)
            {
                if (attempt == 19) return false;
                await Task.Delay(150, cancellationToken).ConfigureAwait(false);
            }
        }
        return false;
    }

    private async Task ListenAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(
                    _pipeName,
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                using var reader = new StreamReader(server, Encoding.UTF8, leaveOpen: true);
                var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (line is null) continue;
                var activation = JsonSerializer.Deserialize<InstanceActivation>(line, JsonOptions);
                if (activation is not null) ActivationReceived?.Invoke(activation);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (IOException)
            {
                if (cancellationToken.IsCancellationRequested) break;
            }
            catch (JsonException)
            {
                // Ignore malformed local messages and continue serving later activations.
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_shutdown is not null)
        {
            await _shutdown.CancelAsync().ConfigureAwait(false);
            if (_listener is not null)
            {
                try { await _listener.ConfigureAwait(false); }
                catch (OperationCanceledException) { }
            }
            _shutdown.Dispose();
        }
        _mutex.Dispose();
    }
}
