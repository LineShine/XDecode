namespace XDecode.Windows.Tests;

public sealed class InstallerSafetyTests
{
    [Fact]
    public void ReinstallDoesNotTerminateUpdaterLaunchedInstaller()
    {
        var script = File.ReadAllText(
            Path.Combine(AppContext.BaseDirectory, "Installer", "XDecode.iss"));

        Assert.Contains("/F /IM XDecode.Windows.exe", script, StringComparison.Ordinal);
        Assert.DoesNotContain("/T /IM XDecode.Windows.exe", script, StringComparison.Ordinal);
    }
}
