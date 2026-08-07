using System.Collections.ObjectModel;
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Windows.Storage.Pickers;
using WinRT.Interop;
using XDecode.Application;
using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed class AppServices : IAsyncDisposable
{
    public SettingsStore Settings { get; }
    public AppOrchestrator Orchestrator { get; }
    public ObservableCollection<DecodeResult> RecentResults { get; } = [];
    public NotificationService Notifications { get; } = new();
    public StartupService Startup { get; } = new();
    public TrayIconService? Tray { get; private set; }

    public AppServices(string localStateDirectory)
    {
        Settings = new SettingsStore(localStateDirectory);
        Orchestrator = new AppOrchestrator(Settings, localStateDirectory);
        Orchestrator.ResultCompleted += OnResultCompleted;
    }

    public async Task InitializeAsync(MainWindow window)
    {
        StartupTrace.Write("Services: loading history");
        foreach (var result in await Orchestrator.LoadHistoryAsync())
            RecentResults.Add(result);
        StartupTrace.Write("Services: initializing notifications");
        Notifications.Initialize();
        StartupTrace.Write("Services: creating tray icon");
        Tray = new TrayIconService(window);
        Tray.OpenRequested += window.ShowAndActivate;
        Tray.SelectFilesRequested += () => _ = PickAndEnqueueAsync(window);
        Tray.SettingsRequested += () => window.NavigateTo("settings");
        Tray.CheckUpdateRequested += () => _ = CheckForUpdatesAsync();
        Tray.ExitRequested += window.ExitApplication;
        Tray.Initialize();
        StartupTrace.Write("Services: tray icon initialized");
        Tray.UpdateRecent(RecentResults.Take(3));
        StartupTrace.Write("Services: starting folder monitoring");
        await Orchestrator.StartMonitoringAsync();
        StartupTrace.Write("Services: folder monitoring started");
    }

    public Task EnqueueAsync(IEnumerable<string> paths, DecodeOrigin origin) =>
        Orchestrator.EnqueueAsync(paths, origin);

    public async Task PickAndEnqueueAsync(Window window)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count > 0)
            await EnqueueAsync(files.Select(value => value.Path), DecodeOrigin.FilePicker);
    }

    public async Task<string?> PickFolderAsync(Window window)
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    public async Task ReloadMonitoringAsync()
    {
        await Settings.SaveAsync();
        await Orchestrator.StartMonitoringAsync();
    }

    public async Task ClearHistoryAsync()
    {
        await Orchestrator.ClearHistoryAsync();
        RecentResults.Clear();
        Tray?.UpdateRecent([]);
    }

    public async Task CheckForUpdatesAsync()
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            var version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "1.0.1";
            var result = await new UpdateChecker(client).CheckAsync(version);
            if (result.IsUpdateAvailable)
            {
                Process.Start(new ProcessStartInfo(result.Release.PageUri.AbsoluteUri)
                {
                    UseShellExecute = true
                });
            }
            else
            {
                Notifications.ShowMessage("检查更新", "当前已是最新版本");
            }
        }
        catch (Exception exception)
        {
            Notifications.ShowMessage("检查更新失败", exception.Message);
        }
    }

    private void OnResultCompleted(DecodeResult result)
    {
        App.CurrentApp.MainWindow.DispatcherQueue.TryEnqueue(() =>
        {
            RecentResults.Insert(0, result);
            while (RecentResults.Count > HistoryStore.MaximumInMemoryCount)
                RecentResults.RemoveAt(RecentResults.Count - 1);
            Tray?.UpdateRecent(RecentResults.Take(3));
            if (Settings.Current.NotificationsEnabled) Notifications.Show(result);
        });
    }

    public async ValueTask DisposeAsync()
    {
        Orchestrator.ResultCompleted -= OnResultCompleted;
        Tray?.Dispose();
        Notifications.Dispose();
        await Orchestrator.DisposeAsync();
    }
}
