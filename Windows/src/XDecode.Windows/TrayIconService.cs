using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed class TrayIconService : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private readonly System.Windows.Forms.ContextMenuStrip _menu = new();
    private readonly List<string> _recent = [];
    private bool _initialized;

    public event Action? OpenRequested;
    public event Action? SelectFilesRequested;
    public event Action? SettingsRequested;
    public event Action? CheckUpdateRequested;
    public event Action? ExitRequested;

    public TrayIconService()
    {
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = "XDecode",
            ContextMenuStrip = _menu
        };
        _icon.MouseClick += (_, arguments) =>
        {
            if (arguments.Button == System.Windows.Forms.MouseButtons.Left)
                OpenRequested?.Invoke();
        };
        RebuildMenu();
    }

    public void Initialize()
    {
        if (_initialized) return;
        _icon.Visible = true;
        _initialized = true;
    }

    public void UpdateRecent(IEnumerable<DecodeResult> results)
    {
        _recent.Clear();
        _recent.AddRange(results.Take(3).Select(value =>
            $"{StateText(value.State)}  {Path.GetFileName(value.Request.SourcePath)}"));
        RebuildMenu();
    }

    private void RebuildMenu()
    {
        _menu.Items.Clear();
        AddCommand("打开 XDecode", () => OpenRequested?.Invoke());
        AddCommand("选择日志...", () => SelectFilesRequested?.Invoke());
        AddCommand("设置", () => SettingsRequested?.Invoke());
        AddCommand("检查更新", () => CheckUpdateRequested?.Invoke());
        if (_recent.Count > 0)
        {
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            foreach (var item in _recent)
                _menu.Items.Add(new System.Windows.Forms.ToolStripMenuItem(item) { Enabled = false });
        }
        _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        AddCommand("退出 XDecode", () => ExitRequested?.Invoke());
    }

    private void AddCommand(string text, Action action)
    {
        var item = new System.Windows.Forms.ToolStripMenuItem(text);
        item.Click += (_, _) => action();
        _menu.Items.Add(item);
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
        if (_initialized) _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
        _initialized = false;
    }
}
