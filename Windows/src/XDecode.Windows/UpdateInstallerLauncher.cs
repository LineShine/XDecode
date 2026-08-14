using System.Diagnostics;

namespace XDecode.WindowsApp;

internal static class UpdateInstallerLauncher
{
    internal static ProcessStartInfo CreateStartInfo(string packagePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packagePath);
        var fullPath = Path.GetFullPath(packagePath);
        var packageDirectory = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidOperationException("无法确定安装包所在目录。");

        return new ProcessStartInfo(fullPath)
        {
            UseShellExecute = true,
            WorkingDirectory = packageDirectory
        };
    }

    internal static void Launch(string packagePath)
    {
        using var process = Process.Start(CreateStartInfo(packagePath));
        if (process is null)
            throw new InvalidOperationException("无法打开安装包。");
    }
}
