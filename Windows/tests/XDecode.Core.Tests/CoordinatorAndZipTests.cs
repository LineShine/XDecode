using System.IO.Compression;
using System.Text;
using XDecode.Core;

namespace XDecode.Core.Tests;

public sealed class CoordinatorAndZipTests
{
    private static readonly string[] ExpectedConcurrentOutputNames =
        ["shared-1.log", "shared.log"];

    [Fact]
    public void OutputNamesReplaceOnlyLastExtension()
    {
        Assert.Equal("archive.part.log", Path.GetFileName(DecodeCoordinator.OutputPath(@"C:\tmp\archive.part.xlog")));
        Assert.Equal("archive.part-1.log", Path.GetFileName(DecodeCoordinator.OutputPath(@"C:\tmp\archive.part.xlog", 1)));
    }

    [Fact]
    public async Task SuccessfulDecodeUsesUniqueNameAndDeletesSource()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "sample.mx");
        var existing = Path.Combine(directory.Path, "sample.log");
        await File.WriteAllTextAsync(source, "encrypted", TestContext.Current.CancellationToken);
        await File.WriteAllTextAsync(existing, "older", TestContext.Current.CancellationToken);
        var coordinator = new DecodeCoordinator((_, _) => ValueTask.FromResult<ILogDecoder>(
            new StubDecoder(DecodedLog.Complete(Encoding.UTF8.GetBytes("decoded")))));
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.FilePicker),
            TestContext.Current.CancellationToken);
        Assert.Equal(DecodeState.Completed, result.State);
        Assert.Equal("sample-1.log", Path.GetFileName(result.OutputPath));
        Assert.False(File.Exists(source));
        Assert.False((File.GetAttributes(result.OutputPath!) & FileAttributes.Hidden) != 0);
        Assert.Equal("decoded", await File.ReadAllTextAsync(
            result.OutputPath!, TestContext.Current.CancellationToken));
        Assert.Equal("older", await File.ReadAllTextAsync(
            existing, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task PartialDecodePreservesSourceAndPublishesNothing()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "partial.xlog");
        await File.WriteAllTextAsync(source, "fixture", TestContext.Current.CancellationToken);
        var coordinator = new DecodeCoordinator((_, _) => ValueTask.FromResult<ILogDecoder>(
            new StubDecoder(DecodedLog.Partial(
                Encoding.UTF8.GetBytes("partial"), "Xlog 部分解密：成功 1 帧，失败 1 帧"))));
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.DragAndDrop),
            TestContext.Current.CancellationToken);
        Assert.Equal(DecodeState.Failed, result.State);
        Assert.True(File.Exists(source));
        Assert.Null(result.OutputPath);
        Assert.False(File.Exists(Path.Combine(directory.Path, "partial.log")));
    }

    [Fact]
    public async Task SourceDeletionFailureKeepsPublishedOutputAsWarning()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "readonly.xlog");
        await File.WriteAllTextAsync(source, "encrypted", TestContext.Current.CancellationToken);
        File.SetAttributes(source, FileAttributes.ReadOnly);
        try
        {
            var coordinator = new DecodeCoordinator((_, _) => ValueTask.FromResult<ILogDecoder>(
                new StubDecoder(DecodedLog.Complete(Encoding.UTF8.GetBytes("decoded")))));
            var result = await coordinator.DecodeAsync(
                new DecodeRequest(source, DecodeOrigin.FilePicker, LogFormat.Xlog),
                TestContext.Current.CancellationToken);
            Assert.Equal(DecodeState.CompletedWithWarning, result.State);
            Assert.True(File.Exists(source));
            Assert.Equal("decoded", await File.ReadAllTextAsync(
                result.OutputPath!, TestContext.Current.CancellationToken));
        }
        finally
        {
            if (File.Exists(source)) File.SetAttributes(source, FileAttributes.Normal);
        }
    }

    [Fact]
    public async Task ConcurrentPublishesNeverOverwrite()
    {
        using var directory = TemporaryDirectory.Create();
        var sources = new[]
        {
            Path.Combine(directory.Path, "shared.xlog"),
            Path.Combine(directory.Path, "shared.mx")
        };
        foreach (var source in sources)
            await File.WriteAllTextAsync(source, "encrypted", TestContext.Current.CancellationToken);
        var resolver = new DecoderResolver((request, _) => ValueTask.FromResult<ILogDecoder>(
            new StubDecoder(DecodedLog.Complete(Encoding.UTF8.GetBytes(Path.GetFileName(request.SourcePath))))));
        var coordinators = sources.Select(_ => new DecodeCoordinator(resolver)).ToArray();
        var requests = sources.Select(path => new DecodeRequest(path, DecodeOrigin.FilePicker, LogFormat.Xlog)).ToArray();
        var results = await Task.WhenAll(coordinators.Select((value, index) =>
            value.DecodeAsync(requests[index], TestContext.Current.CancellationToken)));
        Assert.All(results, result => Assert.Equal(DecodeState.Completed, result.State));
        var outputNames = results
            .Select(value => Path.GetFileName(value.OutputPath!)!)
            .Order(StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(ExpectedConcurrentOutputNames, outputNames);
    }

    [Theory]
    [InlineData("../escape.xlog")]
    [InlineData("/rooted.xlog")]
    [InlineData(@"C:\escape.xlog")]
    [InlineData(@"\\server\share\escape.xlog")]
    [InlineData("safe/file.txt:stream")]
    [InlineData("CON.txt")]
    [InlineData("nested/aux")]
    [InlineData("trailing./file.xlog")]
    [InlineData("trailing /file.xlog")]
    [InlineData("illegal?/file.xlog")]
    [InlineData("control\u0001/file.xlog")]
    public void ZipPathValidatorRejectsWindowsUnsafePaths(string path) =>
        Assert.Throws<DecodeException>(() => ZipPathValidator.ValidateRelativePath(path));

    [Theory]
    [InlineData("safe/file.xlog", "safe/file.xlog")]
    [InlineData(@"safe\nested\file.mx", "safe/nested/file.mx")]
    [InlineData("./safe/file.logan", "safe/file.logan")]
    public void ZipPathValidatorNormalizesSafePaths(string path, string expected) =>
        Assert.Equal(expected, ZipPathValidator.ValidateRelativePath(path));

    [Theory]
    [InlineData("__MACOSX/._first.xlog")]
    [InlineData("nested/._metadata")]
    public void ZipMetadataPathsAreIgnored(string path) =>
        Assert.True(ZipPathValidator.IsMetadataPath(path));

    [Fact]
    public async Task ZipBatchDecodesLogsAndPreservesOtherFiles()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "1_2.zip");
        CreateZip(source, new Dictionary<string, string>
        {
            ["first.xlog"] = "first",
            ["nested/second.mx"] = "second",
            ["notes/readme.txt"] = "keep",
            ["__MACOSX/._first.xlog"] = "metadata"
        });
        var coordinator = new ZipDecodeCoordinator(
            (request, _) => ValueTask.FromResult<ILogDecoder>(new PassthroughDecoder(request.Format)));
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.FilePicker),
            TestContext.Current.CancellationToken);
        Assert.Equal(DecodeState.Completed, result.State);
        Assert.True(File.Exists(source));
        Assert.False((File.GetAttributes(result.OutputPath!) & FileAttributes.Hidden) != 0);
        Assert.Equal("first", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "first.log"), TestContext.Current.CancellationToken));
        Assert.Equal("second", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "nested", "second.log"), TestContext.Current.CancellationToken));
        Assert.Equal("keep", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "notes", "readme.txt"), TestContext.Current.CancellationToken));
        Assert.False(Directory.Exists(Path.Combine(result.OutputPath!, "__MACOSX")));
    }

    [Fact]
    public async Task ZipWithNoSupportedLogsIsSkipped()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "3_4.zip");
        CreateZip(source, new Dictionary<string, string> { ["readme.txt"] = "keep" });
        var coordinator = new ZipDecodeCoordinator(
            (request, _) => ValueTask.FromResult<ILogDecoder>(new PassthroughDecoder(request.Format)));
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.Automatic),
            TestContext.Current.CancellationToken);
        Assert.Equal(DecodeState.Skipped, result.State);
        Assert.Null(result.OutputPath);
        Assert.True(File.Exists(source));
    }

    [Fact]
    public async Task ZipPartialSuccessPreservesFailedPayload()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "5_6.zip");
        CreateZip(source, new Dictionary<string, string>
        {
            ["good.xlog"] = "good",
            ["bad.mx"] = "bad"
        });
        var coordinator = new ZipDecodeCoordinator((request, _) =>
            ValueTask.FromResult<ILogDecoder>(request.Format == LogFormat.Mx
                ? new StubDecoder(DecodedLog.Partial([], "fixture failure"), LogFormat.Mx)
                : new PassthroughDecoder(request.Format)));
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.Automatic),
            TestContext.Current.CancellationToken);
        Assert.Equal(DecodeState.PartiallyCompleted, result.State);
        Assert.Equal("good", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "good.log"), TestContext.Current.CancellationToken));
        Assert.Equal("bad", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "bad.mx"), TestContext.Current.CancellationToken));
        Assert.False(File.Exists(Path.Combine(result.OutputPath!, "bad.log")));
    }

    [Fact]
    public async Task ZipAllFailuresStillPublishOriginalLogs()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "7_8.zip");
        CreateZip(source, new Dictionary<string, string>
        {
            ["first.xlog"] = "first encrypted",
            ["nested/second.mx"] = "second encrypted",
            ["readme.txt"] = "keep"
        });
        var coordinator = new ZipDecodeCoordinator((request, _) =>
            ValueTask.FromResult<ILogDecoder>(
                new StubDecoder(DecodedLog.Partial([], "fixture failure"), request.Format)));
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.Automatic),
            TestContext.Current.CancellationToken);
        Assert.Equal(DecodeState.Failed, result.State);
        Assert.NotNull(result.OutputPath);
        Assert.Equal("first encrypted", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "first.xlog"), TestContext.Current.CancellationToken));
        Assert.Equal("second encrypted", await File.ReadAllTextAsync(
            Path.Combine(result.OutputPath!, "nested", "second.mx"), TestContext.Current.CancellationToken));
        Assert.True(File.Exists(source));
    }

    [Fact]
    public async Task ZipPublicationIsRegisteredBeforeExclusiveRename()
    {
        using var directory = TemporaryDirectory.Create();
        var source = Path.Combine(directory.Path, "9_10.zip");
        CreateZip(source, new Dictionary<string, string> { ["first.xlog"] = "payload" });
        var tracker = new RecordingTracker();
        var coordinator = new ZipDecodeCoordinator(
            (request, _) => ValueTask.FromResult<ILogDecoder>(new PassthroughDecoder(request.Format)),
            publicationTracker: tracker);
        var result = await coordinator.DecodeAsync(
            new DecodeRequest(source, DecodeOrigin.Automatic),
            TestContext.Current.CancellationToken);
        Assert.True(tracker.StagingExisted);
        Assert.False(tracker.DestinationExisted);
        Assert.Equal(result.OutputPath, tracker.Destination);
    }

    private static void CreateZip(string path, IReadOnlyDictionary<string, string> entries)
    {
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, contents) in entries)
        {
            var entry = archive.CreateEntry(name, CompressionLevel.SmallestSize);
            using var writer = new StreamWriter(entry.Open(), Encoding.UTF8);
            writer.Write(contents);
        }
    }

    private sealed class StubDecoder(DecodedLog result, LogFormat format = LogFormat.Xlog) : ILogDecoder
    {
        public LogFormat Format { get; } = format;
        public DecodedLog Decode(ReadOnlyMemory<byte> data, string sourcePath) => result;
    }

    private sealed class PassthroughDecoder(LogFormat format) : ILogDecoder
    {
        public LogFormat Format { get; } = format;
        public DecodedLog Decode(ReadOnlyMemory<byte> data, string sourcePath) =>
            DecodedLog.Complete(data.ToArray());
    }

    private sealed class RecordingTracker : IZipOutputPublicationTracker
    {
        public bool StagingExisted { get; private set; }
        public bool DestinationExisted { get; private set; }
        public string? Destination { get; private set; }

        public ValueTask PreparePublicationAsync(
            string stagingDirectory, string destinationDirectory, CancellationToken cancellationToken)
        {
            StagingExisted = Directory.Exists(stagingDirectory);
            DestinationExisted = Directory.Exists(destinationDirectory);
            Destination = destinationDirectory;
            return ValueTask.CompletedTask;
        }

        public ValueTask CancelPublicationAsync(
            string stagingDirectory, CancellationToken cancellationToken) => ValueTask.CompletedTask;
    }
}

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; }
    private TemporaryDirectory(string path) => Path = path;
    public static TemporaryDirectory Create()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"XDecode-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return new(path);
    }
    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); }
        catch { }
    }
}
