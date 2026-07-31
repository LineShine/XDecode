using XDecode.WindowsApp;

namespace XDecode.Windows.Tests;

public sealed class ActivationParserTests
{
    [Fact]
    public void DirectLaunchShowsWindow()
    {
        var result = ActivationParser.Parse("");
        Assert.True(result.ShowWindow);
        Assert.Equal(XDecode.Core.DecodeOrigin.OpenWith, result.Origin);
        Assert.Empty(result.Paths);
    }

    [Theory]
    [InlineData("--startup")]
    [InlineData("--explorer")]
    [InlineData("--open-with")]
    public void BackgroundActivationsStayHidden(string argument) =>
        Assert.False(ActivationParser.Parse(argument).ShowWindow);

    [Fact]
    public void ExplorerActivationUsesExplorerOrigin() =>
        Assert.Equal(XDecode.Core.DecodeOrigin.Explorer, ActivationParser.Parse("--explorer").Origin);

    [Fact]
    public void ExplorerActivationParsesMultipleQuotedFiles()
    {
        using var directory = TemporaryDirectory.Create();
        var first = Path.Combine(directory.Path, "one file.xlog");
        var second = Path.Combine(directory.Path, "two.mx");
        File.WriteAllText(first, "one");
        File.WriteAllText(second, "two");
        var result = ActivationParser.Parse($"--explorer \"{first}\" \"{second}\"");
        Assert.False(result.ShowWindow);
        Assert.Equal([first, second], result.Paths);
    }
}

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; }
    private TemporaryDirectory(string path) => Path = path;
    public static TemporaryDirectory Create()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"XDecode-Windows-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return new(path);
    }
    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); }
        catch { }
    }
}
