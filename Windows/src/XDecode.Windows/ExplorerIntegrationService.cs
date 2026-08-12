using Microsoft.Win32;
using System.Runtime.InteropServices;

namespace XDecode.WindowsApp;

public sealed class ExplorerIntegrationService
{
    private const string CommandTitle = "使用 XDecode 解密";
    private const string AppliesToSupportedExtensions =
        "System.FileExtension:=\".xlog\" OR " +
        "System.FileExtension:=\".mx\" OR " +
        "System.FileExtension:=\".zip\"";
    private static readonly string[] SupportedExtensions = [".xlog", ".mx", ".zip"];

    private readonly IExplorerIntegrationRegistry _registry;
    private readonly string _iconPath;
    private readonly string _command;

    public ExplorerIntegrationService(string? executablePath = null)
        : this(new CurrentUserExplorerIntegrationRegistry(), executablePath, iconPath: null)
    {
    }

    internal ExplorerIntegrationService(
        IExplorerIntegrationRegistry registry,
        string? executablePath,
        string? iconPath)
    {
        ArgumentNullException.ThrowIfNull(registry);
        executablePath ??= Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath))
            throw new InvalidOperationException("无法确定 XDecode 可执行文件路径");

        var fullExecutablePath = Path.GetFullPath(executablePath);
        _registry = registry;
        _iconPath = iconPath ?? Path.Combine(
            Path.GetDirectoryName(fullExecutablePath)!, "Assets", "XDecode.ico");
        _command = $"\"{fullExecutablePath}\" --explorer \"%1\"";
    }

    public bool EnsureRegistered()
    {
        try
        {
            var placeAfterNotepad = _registry.HasNotepadVerb();
            _registry.DeleteExistingVerbs(SupportedExtensions);
            if (placeAfterNotepad)
            {
                _registry.SetVerbAfterNotepad(
                    CommandTitle,
                    _iconPath,
                    _command,
                    AppliesToSupportedExtensions);
            }
            else
            {
                foreach (var extension in SupportedExtensions)
                    _registry.SetTopVerb(extension, CommandTitle, _iconPath, _command);
            }
            _registry.NotifyShellAssociationsChanged();
            return true;
        }
        catch (Exception exception) when (IsRegistryAccessFailure(exception))
        {
            return false;
        }
    }

    private static bool IsRegistryAccessFailure(Exception exception) =>
        exception is UnauthorizedAccessException or
        System.Security.SecurityException or
        IOException;
}

internal interface IExplorerIntegrationRegistry
{
    bool HasNotepadVerb();
    void DeleteExistingVerbs(IEnumerable<string> extensions);
    void SetVerbAfterNotepad(string title, string iconPath, string command, string appliesTo);
    void SetTopVerb(string extension, string title, string iconPath, string command);
    void NotifyShellAssociationsChanged();
}

internal sealed class CurrentUserExplorerIntegrationRegistry : IExplorerIntegrationRegistry
{
    private const uint AssociationChangedEvent = 0x08000000;
    private const string LegacyWildcardVerbPath =
        @"Software\Classes\*\shell\XDecodeDecrypt";
    private const string NotepadVerbPath = @"*\shell\Notepad";
    private const string VerbAfterNotepadPath =
        @"Software\Classes\*\shell\Notepad.XDecodeDecrypt";

    public bool HasNotepadVerb()
    {
        using var key = Registry.ClassesRoot.OpenSubKey(NotepadVerbPath, writable: false);
        return key is not null;
    }

    public void DeleteExistingVerbs(IEnumerable<string> extensions)
    {
        Registry.CurrentUser.DeleteSubKeyTree(LegacyWildcardVerbPath, throwOnMissingSubKey: false);
        Registry.CurrentUser.DeleteSubKeyTree(VerbAfterNotepadPath, throwOnMissingSubKey: false);
        foreach (var extension in extensions)
        {
            Registry.CurrentUser.DeleteSubKeyTree(
                VerbPathForExtension(extension),
                throwOnMissingSubKey: false);
        }
    }

    public void SetVerbAfterNotepad(
        string title,
        string iconPath,
        string command,
        string appliesTo)
    {
        using var verbKey = CreateVerbKey(VerbAfterNotepadPath, "Notepad");
        SetCommonValues(verbKey, title, iconPath);
        verbKey.SetValue("AppliesTo", appliesTo, RegistryValueKind.String);
        verbKey.DeleteValue("Position", throwOnMissingValue: false);
        SetCommand(verbKey, command, "Notepad");
    }

    public void SetTopVerb(string extension, string title, string iconPath, string command)
    {
        using var verbKey = CreateVerbKey(VerbPathForExtension(extension), extension);
        SetCommonValues(verbKey, title, iconPath);
        verbKey.SetValue("Position", "Top", RegistryValueKind.String);
        verbKey.DeleteValue("AppliesTo", throwOnMissingValue: false);
        SetCommand(verbKey, command, extension);
    }

    private static string VerbPathForExtension(string extension) =>
        $@"Software\Classes\SystemFileAssociations\{extension}\shell\XDecodeDecrypt";

    private static RegistryKey CreateVerbKey(string path, string description) =>
        Registry.CurrentUser.CreateSubKey(path, writable: true)
        ?? throw new IOException($"无法创建资源管理器右键注册项：{description}");

    private static void SetCommonValues(RegistryKey verbKey, string title, string iconPath)
    {
        verbKey.SetValue(string.Empty, title, RegistryValueKind.String);
        verbKey.SetValue("MUIVerb", title, RegistryValueKind.String);
        verbKey.SetValue("Icon", iconPath, RegistryValueKind.String);
        verbKey.SetValue("MultiSelectModel", "Player", RegistryValueKind.String);
        verbKey.DeleteValue("ExplorerCommandHandler", throwOnMissingValue: false);
        verbKey.DeleteValue("DelegateExecute", throwOnMissingValue: false);
    }

    private static void SetCommand(RegistryKey verbKey, string command, string description)
    {
        using var commandKey = verbKey.CreateSubKey("command", writable: true)
            ?? throw new IOException($"无法创建资源管理器右键命令：{description}");
        commandKey.SetValue(string.Empty, command, RegistryValueKind.String);
    }

    public void NotifyShellAssociationsChanged() =>
        SHChangeNotify(AssociationChangedEvent, flags: 0, IntPtr.Zero, IntPtr.Zero);

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(
        uint eventId,
        uint flags,
        IntPtr item1,
        IntPtr item2);
}
