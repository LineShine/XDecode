using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed class NotificationService : IDisposable
{
    private bool _registered;

    public void Initialize()
    {
        if (_registered) return;
        AppNotificationManager.Default.Register();
        _registered = true;
    }

    public void Show(DecodeResult result)
    {
        if (!_registered || result.State == DecodeState.Skipped) return;
        var title = result.State switch
        {
            DecodeState.Completed => "解密完成",
            DecodeState.PartiallyCompleted => "ZIP 部分解密完成",
            DecodeState.CompletedWithWarning => "解密完成但有警告",
            _ => "解密失败"
        };
        var builder = new AppNotificationBuilder()
            .AddText(title)
            .AddText(Path.GetFileName(result.Request.SourcePath))
            .AddText(result.Message);
        if (result.OutputPath is not null)
            builder.AddArgument("output", result.OutputPath);
        AppNotificationManager.Default.Show(builder.BuildNotification());
    }

    public void ShowMessage(string title, string message)
    {
        if (!_registered) return;
        AppNotificationManager.Default.Show(
            new AppNotificationBuilder().AddText(title).AddText(message).BuildNotification());
    }

    public void Dispose()
    {
        if (!_registered) return;
        AppNotificationManager.Default.Unregister();
        _registered = false;
    }
}
