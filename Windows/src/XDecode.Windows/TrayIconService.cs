using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;
using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed class TrayIconService : IDisposable
{
    private const uint WmApp = 0x8000;
    private const uint TrayMessage = WmApp + 0x41;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmRButtonUp = 0x0205;
    private const uint NimAdd = 0;
    private const uint NimDelete = 2;
    private const uint NifMessage = 1;
    private const uint NifIcon = 2;
    private const uint NifTip = 4;
    private const uint MfString = 0;
    private const uint MfSeparator = 0x800;
    private const uint TpmReturnCmd = 0x100;
    private const uint TpmRightButton = 2;
    private const uint IdOpen = 1;
    private const uint IdSelect = 2;
    private const uint IdSettings = 3;
    private const uint IdUpdate = 4;
    private const uint IdExit = 5;
    private const nuint SubclassId = 0x58444543;

    private readonly nint _windowHandle;
    private readonly SubclassProcedure _subclassProcedure;
    private readonly List<string> _recent = [];
    private NotifyIconData _iconData;
    private bool _initialized;

    public event Action? OpenRequested;
    public event Action? SelectFilesRequested;
    public event Action? SettingsRequested;
    public event Action? CheckUpdateRequested;
    public event Action? ExitRequested;

    public TrayIconService(Window window)
    {
        _windowHandle = WindowNative.GetWindowHandle(window);
        _subclassProcedure = WindowSubclass;
    }

    public void Initialize()
    {
        if (_initialized) return;
        SetWindowSubclass(_windowHandle, _subclassProcedure, SubclassId, 0);
        _iconData = new NotifyIconData
        {
            Size = checked((uint)Marshal.SizeOf<NotifyIconData>()),
            Window = _windowHandle,
            Id = 1,
            Flags = NifMessage | NifIcon | NifTip,
            CallbackMessage = TrayMessage,
            Icon = LoadIcon(0, (nint)32512),
            Tip = "XDecode",
            Info = "",
            InfoTitle = ""
        };
        if (!ShellNotifyIcon(NimAdd, ref _iconData))
            throw new InvalidOperationException("无法创建 XDecode 系统托盘图标");
        _initialized = true;
    }

    public void UpdateRecent(IEnumerable<DecodeResult> results)
    {
        _recent.Clear();
        _recent.AddRange(results.Take(3).Select(value =>
            $"{StateText(value.State)}  {Path.GetFileName(value.Request.SourcePath)}"));
    }

    private nint WindowSubclass(
        nint window, uint message, nuint wParam, nint lParam, nuint id, nint referenceData)
    {
        if (message == TrayMessage)
        {
            var action = unchecked((uint)lParam.ToInt64());
            if (action == WmLButtonUp) OpenRequested?.Invoke();
            else if (action == WmRButtonUp) ShowContextMenu();
            return 0;
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        try
        {
            AppendMenu(menu, MfString, IdOpen, "打开 XDecode");
            AppendMenu(menu, MfString, IdSelect, "选择日志...");
            AppendMenu(menu, MfString, IdSettings, "设置");
            AppendMenu(menu, MfString, IdUpdate, "检查更新");
            if (_recent.Count > 0)
            {
                AppendMenu(menu, MfSeparator, 0, null);
                foreach (var item in _recent) AppendMenu(menu, MfString | 0x1, 0, item);
            }
            AppendMenu(menu, MfSeparator, 0, null);
            AppendMenu(menu, MfString, IdExit, "退出 XDecode");
            GetCursorPos(out var point);
            SetForegroundWindow(_windowHandle);
            var command = TrackPopupMenu(
                menu, TpmReturnCmd | TpmRightButton, point.X, point.Y, 0, _windowHandle, 0);
            switch (command)
            {
                case IdOpen: OpenRequested?.Invoke(); break;
                case IdSelect: SelectFilesRequested?.Invoke(); break;
                case IdSettings: SettingsRequested?.Invoke(); break;
                case IdUpdate: CheckUpdateRequested?.Invoke(); break;
                case IdExit: ExitRequested?.Invoke(); break;
            }
        }
        finally { DestroyMenu(menu); }
    }

    private static string StateText(DecodeState state) => state switch
    {
        DecodeState.Completed => "成功",
        DecodeState.PartiallyCompleted => "部分成功",
        DecodeState.CompletedWithWarning => "有警告",
        _ => "失败"
    };

    public void Dispose()
    {
        if (!_initialized) return;
        ShellNotifyIcon(NimDelete, ref _iconData);
        RemoveWindowSubclass(_windowHandle, _subclassProcedure, SubclassId);
        _initialized = false;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;
        public uint InfoFlags;
        public Guid GuidItem;
        public nint BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X; public int Y; }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProcedure(
        nint window, uint message, nuint wParam, nint lParam, nuint id, nint referenceData);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", EntryPoint = "LoadIconW")]
    private static extern nint LoadIcon(nint instance, nint iconName);
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(
        nint window, SubclassProcedure callback, nuint id, nint referenceData);
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint window, SubclassProcedure callback, nuint id);
    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenu(
        nint menu, uint flags, int x, int y, int reserved, nint window, nint rectangle);
}
