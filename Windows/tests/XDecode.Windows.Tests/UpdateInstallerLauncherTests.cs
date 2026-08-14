using XDecode.WindowsApp;

namespace XDecode.Windows.Tests;

public sealed class UpdateInstallerLauncherTests
{
    [Fact]
    public void InstallerUsesItsDownloadDirectoryAsTheWorkingDirectory()
    {
        var packagePath = Path.Combine(
            Path.GetTempPath(),
            "XDecode update",
            "XDecode-Setup-x64.exe");
        var fullPath = Path.GetFullPath(packagePath);

        var startInfo = UpdateInstallerLauncher.CreateStartInfo(packagePath);

        Assert.True(startInfo.UseShellExecute);
        Assert.Equal(fullPath, startInfo.FileName);
        Assert.Equal(Path.GetDirectoryName(fullPath), startInfo.WorkingDirectory);
    }
}
