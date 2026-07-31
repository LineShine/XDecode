using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using XDecode.Application;
using XDecode.Core;

namespace XDecode.Application.Tests;

public sealed class SettingsAndServicesTests
{
    [Theory]
    [InlineData("host_????.xlog", "HOST_2026.XLOG", true)]
    [InlineData("host_????.xlog", "host_26.xlog", false)]
    [InlineData("yyyy-MM-dd", "2026-07-27", true)]
    [InlineData("yyyy-MM-dd", "2026-7-27", false)]
    [InlineData(@"^release\..+\.zip$", "release.prod.zip", true)]
    [InlineData(@"^release\..+\.zip$", "other.prod.zip", false)]
    public void FilenameRulesMatchAsSpecified(string pattern, string fileName, bool expected) =>
        Assert.Equal(expected, FilenamePattern.Matches(pattern, Path.Combine(@"C:\logs", fileName)));

    [Theory]
    [InlineData("a_b.zip", true)]
    [InlineData("abc-def.ZIP", true)]
    [InlineData("338911075_20059056_1logs.zip", true)]
    [InlineData("archive.zip", false)]
    [InlineData("abc--def.zip", false)]
    [InlineData("user cache.zip", false)]
    [InlineData("日志_123.zip", false)]
    public void DefaultZipRuleMatchesProductContract(string fileName, bool expected) =>
        Assert.Equal(expected, FilenamePattern.Matches(FilenamePatternDefaults.Zip, fileName));

    [Fact]
    public async Task FirstInstallEnablesDownloadsAndExplicitRemovalPersists()
    {
        using var directory = TemporaryDirectory.Create();
        var downloads = Path.Combine(directory.Path, "Downloads");
        Directory.CreateDirectory(downloads);
        var settings = new SettingsStore(directory.Path, downloads);
        Assert.True(settings.Current.AutomaticEnabled);
        Assert.True(settings.Current.DownloadsMonitoringEnabled);
        Assert.Equal([downloads], settings.MonitoredFolders);
        await settings.RemoveMonitoredFolderAsync(downloads, TestContext.Current.CancellationToken);
        var restored = new SettingsStore(directory.Path, downloads);
        Assert.False(restored.Current.DownloadsMonitoringEnabled);
        Assert.Empty(restored.MonitoredFolders);
    }

    [Fact]
    public async Task DpapiSecretsAreNotWrittenInPlaintextOrMetadata()
    {
        using var directory = TemporaryDirectory.Create();
        var settings = new SettingsStore(directory.Path, Path.Combine(directory.Path, "Downloads"));
        var profile = new XlogProfile(Guid.NewGuid(), "Secret", "*.xlog");
        settings.Current.XlogProfiles.Add(profile);
        var secret = Enumerable.Repeat((byte)0, 31).Append((byte)1).ToArray();
        await settings.SaveXlogPrivateKeyAsync(
            profile.Id, secret, TestContext.Current.CancellationToken);
        var settingsJson = await File.ReadAllTextAsync(
            Path.Combine(directory.Path, "settings.v1.json"), TestContext.Current.CancellationToken);
        var secretJson = await File.ReadAllTextAsync(
            Path.Combine(directory.Path, "secrets.v1.json"), TestContext.Current.CancellationToken);
        Assert.DoesNotContain(Convert.ToHexString(secret), settingsJson, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(Convert.ToBase64String(secret), secretJson, StringComparison.Ordinal);
        var restored = new SettingsStore(directory.Path, Path.Combine(directory.Path, "Downloads"));
        Assert.Single(restored.XlogCredentialsFor("sample.xlog"));
    }

    [Fact]
    public async Task ExplicitLoganProfileDisablesDefaultDateRule()
    {
        using var directory = TemporaryDirectory.Create();
        var settings = new SettingsStore(directory.Path, Path.Combine(directory.Path, "Downloads"));
        settings.Current.LoganProfiles.Add(new(
            Guid.NewGuid(), "Custom", "device-*"));
        await settings.SaveAsync(TestContext.Current.CancellationToken);
        Assert.Null(settings.LogFormatFor("2026-07-27"));
        Assert.Equal(LogFormat.Logan, settings.LogFormatFor("device-current"));
        Assert.Equal(LogFormat.Logan, settings.LogFormatFor("anything.logan"));
    }

    [Fact]
    public async Task HistorySkipsSkippedResultsAndRetainsNewestThirtyInMemory()
    {
        using var directory = TemporaryDirectory.Create();
        await using var history = new HistoryStore(directory.Path);
        for (var index = 0; index < 35; index++)
        {
            var request = new DecodeRequest($"C:\\logs\\{index}.xlog", DecodeOrigin.FilePicker, LogFormat.Xlog);
            await history.AppendAsync(new DecodeResult(
                request, DecodeState.Completed, $"C:\\logs\\{index}.log",
                index.ToString(CultureInfo.InvariantCulture), true),
                TestContext.Current.CancellationToken);
        }
        var skippedRequest = new DecodeRequest(@"C:\logs\skip.zip", DecodeOrigin.Automatic, LogFormat.Zip);
        await history.AppendAsync(new DecodeResult(
            skippedRequest, DecodeState.Skipped, null, "skip", false),
            TestContext.Current.CancellationToken);
        var loaded = await history.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(30, loaded.Count);
        Assert.DoesNotContain(loaded, value => value.State == DecodeState.Skipped);
    }

    [Fact]
    public async Task QueueIsUnboundedDeduplicatesPathsAndRunsAtMostTwo()
    {
        var running = 0;
        var maximum = 0;
        var release = new SemaphoreSlim(0);
        await using var queue = new DecodeTaskQueue(async (request, cancellationToken) =>
        {
            var value = Interlocked.Increment(ref running);
            maximum = Math.Max(maximum, value);
            await release.WaitAsync(cancellationToken);
            Interlocked.Decrement(ref running);
            return new DecodeResult(request, DecodeState.Completed, null, "done", true);
        });
        var tasks = Enumerable.Range(0, 10).Select(index =>
            queue.EnqueueAsync(new DecodeRequest(
                $"C:\\logs\\{index}.xlog", DecodeOrigin.FilePicker, LogFormat.Xlog),
                TestContext.Current.CancellationToken)).ToArray();
        var duplicate = queue.EnqueueAsync(new DecodeRequest(
            @"c:\LOGS\0.xlog", DecodeOrigin.FilePicker, LogFormat.Xlog),
            TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.Equal(2, maximum);
        Assert.Null(await duplicate);
        release.Release(10);
        await Task.WhenAll(tasks);
    }

    [Fact]
    public async Task QueueShutdownCancelsRunningAndPendingTasks()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queue = new DecodeTaskQueue(async (request, cancellationToken) =>
        {
            started.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return new DecodeResult(request, DecodeState.Completed, null, "done", true);
        }, maximumConcurrency: 1);
        var running = queue.EnqueueAsync(new DecodeRequest(
            @"C:\logs\running.xlog", DecodeOrigin.FilePicker, LogFormat.Xlog));
        var pending = queue.EnqueueAsync(new DecodeRequest(
            @"C:\logs\pending.xlog", DecodeOrigin.FilePicker, LogFormat.Xlog));
        await started.Task.WaitAsync(
            TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        await queue.DisposeAsync();

        Assert.True(running.IsCanceled);
        Assert.True(pending.IsCanceled);
        Assert.Equal(0, queue.ScheduledCount);
    }

    [Fact]
    public async Task StabilityGateRequiresTwoUnchangedSamplesAndDeduplicates()
    {
        using var directory = TemporaryDirectory.Create();
        var path = Path.Combine(directory.Path, "sample.xlog");
        await File.WriteAllTextAsync(path, "stable", TestContext.Current.CancellationToken);
        var gate = new FileStabilityGate();
        var first = gate.WaitUntilStableAsync(
            path, checks: 2, interval: TimeSpan.FromMilliseconds(20), timeout: TimeSpan.FromSeconds(1),
            cancellationToken: TestContext.Current.CancellationToken);
        var duplicate = await gate.WaitUntilStableAsync(
            path, checks: 2, interval: TimeSpan.FromMilliseconds(20), timeout: TimeSpan.FromSeconds(1),
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.False(duplicate);
        Assert.True(await first);
    }

    [Fact]
    public async Task FolderMonitorDoesNotEmitPreexistingFiles()
    {
        using var directory = TemporaryDirectory.Create();
        await File.WriteAllTextAsync(
            Path.Combine(directory.Path, "old.xlog"), "old", TestContext.Current.CancellationToken);
        using var monitor = new FolderMonitorService();
        var received = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        monitor.NewFile += path =>
        {
            received.TrySetResult(path);
            return Task.CompletedTask;
        };
        await monitor.StartAsync([directory.Path], TestContext.Current.CancellationToken);
        await File.WriteAllTextAsync(
            Path.Combine(directory.Path, "new.xlog"), "new", TestContext.Current.CancellationToken);
        var emitted = await received.Task.WaitAsync(
            TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal("new.xlog", Path.GetFileName(emitted));
    }

    [Fact]
    public async Task ZipOutputSuppressionPersistsAndConsumesFileIdentityOnce()
    {
        using var directory = TemporaryDirectory.Create();
        var state = Path.Combine(directory.Path, "state");
        var staging = Path.Combine(directory.Path, ".xdecode-zip.tmp");
        var destination = Path.Combine(directory.Path, "output");
        Directory.CreateDirectory(staging);
        await File.WriteAllTextAsync(
            Path.Combine(staging, "first.xlog"), "payload", TestContext.Current.CancellationToken);
        var store = new AutomaticDecodeSuppressionStore(state);
        await store.PreparePublicationAsync(
            staging, destination, TestContext.Current.CancellationToken);
        Directory.Move(staging, destination);

        var restored = new AutomaticDecodeSuppressionStore(state);
        var publishedPath = Path.Combine(destination, "first.xlog");
        Assert.True(await restored.ConsumeIfRegisteredAsync(
            publishedPath, TestContext.Current.CancellationToken));
        Assert.False(await restored.ConsumeIfRegisteredAsync(
            publishedPath, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("v1.2.3", "1.2.3", false)]
    [InlineData("1.2.4", "1.2.3", true)]
    [InlineData("2.0", "1.99.99", true)]
    public void SemanticVersionsCompareCorrectly(string latest, string current, bool newer) =>
        Assert.Equal(newer, UpdateChecker.ParseVersion(latest) > UpdateChecker.ParseVersion(current));

    [Fact]
    public async Task UpdateCheckerUsesGitHubMetadataOnly()
    {
        var handler = new StubHttpHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                """{"tag_name":"v2.0.0","html_url":"https://github.com/LineShine/XDecode/releases/tag/v2.0.0"}""",
                Encoding.UTF8, "application/json")
        });
        using var client = new HttpClient(handler);
        var result = await new UpdateChecker(client).CheckAsync(
            "1.0.0", TestContext.Current.CancellationToken);
        Assert.True(result.IsUpdateAvailable);
        Assert.Equal(HttpMethod.Get, handler.Request?.Method);
        Assert.Equal(UpdateChecker.LatestReleaseEndpoint, handler.Request?.RequestUri);
    }

    private sealed class StubHttpHandler(HttpResponseMessage response) : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Request = request;
            return Task.FromResult(response);
        }
    }
}

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; }
    private TemporaryDirectory(string path) => Path = path;
    public static TemporaryDirectory Create()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"XDecode-App-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return new(path);
    }
    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); }
        catch { }
    }
}
