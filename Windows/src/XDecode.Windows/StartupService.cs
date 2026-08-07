using Microsoft.Win32;

namespace XDecode.WindowsApp;

public sealed class StartupService
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovalKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "XDecode";
    private readonly string _command;

    public StartupService(string? executablePath = null)
    {
        executablePath ??= Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath))
            throw new InvalidOperationException("无法确定 XDecode 可执行文件路径");
        _command = $"\"{Path.GetFullPath(executablePath)}\" --startup";
    }

    public Task<bool> GetStateAsync()
    {
        try { return Task.FromResult(IsEnabled()); }
        catch (Exception exception) when (IsRegistryAccessFailure(exception))
        {
            return Task.FromResult(false);
        }
    }

    public Task<bool> SetEnabledAsync(bool enabled)
    {
        try
        {
            using (var runKey = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true))
            {
                if (enabled)
                    runKey.SetValue(ValueName, _command, RegistryValueKind.String);
                else
                    runKey.DeleteValue(ValueName, throwOnMissingValue: false);
            }

            using var approvalKey = Registry.CurrentUser.OpenSubKey(ApprovalKeyPath, writable: true);
            approvalKey?.DeleteValue(ValueName, throwOnMissingValue: false);
            return Task.FromResult(enabled && IsEnabled());
        }
        catch (Exception exception) when (IsRegistryAccessFailure(exception))
        {
            return Task.FromResult(false);
        }
    }

    private static bool IsEnabled()
    {
        using var runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        if (runKey?.GetValue(ValueName) is not string command || string.IsNullOrWhiteSpace(command))
            return false;

        using var approvalKey = Registry.CurrentUser.OpenSubKey(ApprovalKeyPath);
        return approvalKey?.GetValue(ValueName) is not byte[] approval ||
               approval.Length == 0 ||
               approval[0] == 0x02;
    }

    private static bool IsRegistryAccessFailure(Exception exception) =>
        exception is UnauthorizedAccessException or
        System.Security.SecurityException or
        IOException;
}
