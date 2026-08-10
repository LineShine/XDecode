using Microsoft.Win32;

namespace XDecode.WindowsApp;

public sealed class StartupService
{
    private readonly IStartupRegistry _registry;
    private readonly string _command;

    public StartupService(string? executablePath = null)
        : this(new CurrentUserStartupRegistry(), executablePath)
    {
    }

    internal StartupService(IStartupRegistry registry, string? executablePath = null)
    {
        ArgumentNullException.ThrowIfNull(registry);
        executablePath ??= Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath))
            throw new InvalidOperationException("无法确定 XDecode 可执行文件路径");

        _registry = registry;
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
            if (enabled)
                _registry.SetValue(_command);
            else
                _registry.DeleteValue();
        }
        catch (Exception exception) when (IsRegistryAccessFailure(exception))
        {
            // The setting must reflect the entry that Windows will actually use,
            // even when changing the registry value was denied.
        }

        return GetStateAsync();
    }

    private bool IsEnabled() => !string.IsNullOrWhiteSpace(_registry.GetValue());

    private static bool IsRegistryAccessFailure(Exception exception) =>
        exception is UnauthorizedAccessException or
        System.Security.SecurityException or
        IOException;
}

internal interface IStartupRegistry
{
    string? GetValue();
    void SetValue(string command);
    void DeleteValue();
}

internal sealed class CurrentUserStartupRegistry : IStartupRegistry
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "XDecode";

    public string? GetValue()
    {
        using var runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return runKey?.GetValue(ValueName) as string;
    }

    public void SetValue(string command)
    {
        using var runKey = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
        runKey.SetValue(ValueName, command, RegistryValueKind.String);
    }

    public void DeleteValue()
    {
        using var runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        runKey?.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
