using System.Diagnostics;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDecode.Application;
using XDecode.Core;

namespace XDecode.WindowsApp.Pages;

public sealed partial class SettingsPage : Page
{
    private readonly SettingsStore _settings = App.CurrentApp.Services.Settings;
    private bool _loading = true;
    private bool _isCheckingForUpdates;
    private bool _isDownloadingUpdate;
    private Guid? _editingXlog;
    private Guid? _editingLogan;

    public SettingsPage()
    {
        InitializeComponent();
        AutomaticToggle.IsOn = _settings.Current.AutomaticEnabled;
        NotificationToggle.IsOn = _settings.Current.NotificationsEnabled;
        MxPattern.Text = _settings.Current.MxFilePattern;
        VersionText.Text = $"当前版本 {CurrentVersion}";
        RefreshFolders();
        RefreshProfiles();
        RefreshZipRules();
        _loading = false;
        _ = LoadStartupStateAsync();
    }

    private static string CurrentVersion =>
        typeof(App).Assembly.GetName().Version?.ToString(3) ?? "1.0.5";

    private async Task LoadStartupStateAsync()
    {
        var enabled = await App.CurrentApp.Services.Startup.GetStateAsync();
        _loading = true;
        StartupToggle.IsOn = enabled;
        _loading = false;
    }

    private async void AutomaticToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.AutomaticEnabled = AutomaticToggle.IsOn;
        await App.CurrentApp.Services.ReloadMonitoringAsync();
        App.CurrentApp.MainWindow.RefreshAutomationStatus();
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var path = await App.CurrentApp.Services.PickFolderAsync(App.CurrentApp.MainWindow);
        if (path is null) return;
        await _settings.AddMonitoredFolderAsync(path);
        await App.CurrentApp.Services.ReloadMonitoringAsync();
        RefreshFolders();
    }

    private async void RemoveFolder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string path }) return;
        await _settings.RemoveMonitoredFolderAsync(path);
        await App.CurrentApp.Services.ReloadMonitoringAsync();
        RefreshFolders();
    }

    private async void NotificationToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.NotificationsEnabled = NotificationToggle.IsOn;
        await _settings.SaveAsync();
    }

    private async void StartupToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var enabled = await App.CurrentApp.Services.Startup.SetEnabledAsync(StartupToggle.IsOn);
        _settings.Current.LaunchAtLoginEnabled = enabled;
        await _settings.SaveAsync();
        if (StartupToggle.IsOn == enabled) return;
        _loading = true;
        StartupToggle.IsOn = enabled;
        _loading = false;
    }

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
        => await CheckForUpdatesAsync();

    public async Task CheckForUpdatesAsync()
    {
        if (_isCheckingForUpdates || _isDownloadingUpdate) return;
        _isCheckingForUpdates = true;
        SetUpdateState("正在检查...", isBusy: true);
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            var result = await new UpdateChecker(client).CheckAsync(CurrentVersion);
            if (!result.IsUpdateAvailable)
            {
                ShowUpdateInfo(
                    InfoBarSeverity.Success,
                    "当前已是最新版本",
                    $"当前版本 {CurrentVersion} 已是最新版本。");
                return;
            }

            var release = result.Release;
            var notes = string.IsNullOrWhiteSpace(release.ReleaseNotes)
                ? "此版本未提供发布说明。"
                : release.ReleaseNotes.Trim();
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "发现新版本",
                PrimaryButtonText = "下载更新",
                CloseButtonText = "稍后",
                DefaultButton = ContentDialogButton.Primary,
                Content = new StackPanel
                {
                    Spacing = 10,
                    MinWidth = 420,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = $"XDecode {release.Version} 已发布，当前版本为 {CurrentVersion}。"
                        },
                        new TextBlock
                        {
                            Text = $"安装包大小：{FormatSize(release.SizeBytes)}",
                            Style = (Style)Microsoft.UI.Xaml.Application.Current.Resources[
                                "CaptionTextStyle"]
                        },
                        new TextBlock
                        {
                            Text = notes,
                            TextWrapping = TextWrapping.Wrap,
                            MaxHeight = 180
                        }
                    }
                }
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                await DownloadUpdateAsync(release);
        }
        catch (Exception exception)
        {
            ShowError(UpdateInfo, exception.Message);
        }
        finally
        {
            _isCheckingForUpdates = false;
            if (!_isDownloadingUpdate) SetUpdateState("检查更新", isBusy: false);
        }
    }

    private async Task DownloadUpdateAsync(UpdateRelease release)
    {
        _isDownloadingUpdate = true;
        UpdateProgress.Value = 0;
        UpdateProgress.Visibility = Visibility.Visible;
        SetUpdateState("正在下载...", isBusy: true);
        var progress = new Progress<UpdateDownloadProgress>(value =>
        {
            UpdateProgress.Value = value.Percentage;
            UpdateButtonText.Text = $"正在下载 {value.Percentage:0}%";
        });

        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
            var packagePath = await new UpdatePackageDownloader(client)
                .DownloadAsync(release, progress);
            Process.Start(new ProcessStartInfo(packagePath) { UseShellExecute = true });

            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "安装包已打开",
                Content = "请退出 XDecode，然后在安装窗口中完成更新。",
                PrimaryButtonText = "退出 XDecode",
                CloseButtonText = "稍后",
                DefaultButton = ContentDialogButton.Primary
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                App.CurrentApp.MainWindow.ExitApplication();
        }
        catch (Exception exception)
        {
            ShowError(UpdateInfo, exception.Message);
        }
        finally
        {
            _isDownloadingUpdate = false;
            UpdateProgress.Visibility = Visibility.Collapsed;
            SetUpdateState("检查更新", isBusy: false);
        }
    }

    private void SetUpdateState(string buttonText, bool isBusy)
    {
        UpdateButtonText.Text = buttonText;
        UpdateButton.IsEnabled = !isBusy;
    }

    private void ShowUpdateInfo(InfoBarSeverity severity, string title, string message)
    {
        UpdateInfo.IsOpen = true;
        UpdateInfo.Severity = severity;
        UpdateInfo.Title = title;
        UpdateInfo.Message = message;
    }

    private static string FormatSize(long sizeBytes) => sizeBytes switch
    {
        >= 1_073_741_824 => $"{sizeBytes / 1_073_741_824d:0.0} GiB",
        >= 1_048_576 => $"{sizeBytes / 1_048_576d:0.0} MiB",
        >= 1_024 => $"{sizeBytes / 1_024d:0.0} KiB",
        _ => $"{sizeBytes} 字节"
    };

    private async void ZipPattern_LostFocus(object sender, RoutedEventArgs e)
    {
        if (sender is not TextBox { Tag: Guid id } textBox) return;
        var index = _settings.Current.ZipPatternRules.FindIndex(value => value.Id == id);
        if (index < 0) return;
        _settings.Current.ZipPatternRules[index] =
            _settings.Current.ZipPatternRules[index] with { Pattern = textBox.Text.Trim() };
        await _settings.SaveAsync();
    }

    private async void ResetZipRule_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Guid id }) return;
        var index = _settings.Current.ZipPatternRules.FindIndex(value => value.Id == id);
        if (index < 0) return;
        _settings.Current.ZipPatternRules[index] =
            _settings.Current.ZipPatternRules[index] with { Pattern = FilenamePatternDefaults.Zip };
        await _settings.SaveAsync();
        RefreshZipRules();
    }

    private async void AddZipRule_Click(object sender, RoutedEventArgs e)
    {
        _settings.Current.ZipPatternRules.Add(
            new ZipPatternRule(Guid.NewGuid(), FilenamePatternDefaults.Zip));
        await _settings.SaveAsync();
        RefreshZipRules();
    }

    private async void DeleteZipRule_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Guid id } ||
            _settings.Current.ZipPatternRules.Count <= 1) return;
        _settings.Current.ZipPatternRules.RemoveAll(value => value.Id == id);
        await _settings.SaveAsync();
        RefreshZipRules();
    }

    private async void MxPattern_LostFocus(object sender, RoutedEventArgs e)
    {
        _settings.Current.MxFilePattern = MxPattern.Text.Trim();
        await _settings.SaveAsync();
    }

    private async void ResetMxPattern_Click(object sender, RoutedEventArgs e)
    {
        MxPattern.Text = FilenamePatternDefaults.Mx;
        _settings.Current.MxFilePattern = FilenamePatternDefaults.Mx;
        await _settings.SaveAsync();
    }

    private async void AddXlog_Click(object sender, RoutedEventArgs e)
    {
        _editingXlog = null;
        XlogName.Text = "默认环境";
        XlogPattern.Text = FilenamePatternDefaults.Xlog;
        XlogKey.Password = "";
        XlogKey.Header = "64 位 Hex 私钥";
        XlogSecretHint.Visibility = Visibility.Collapsed;
        XlogInfo.IsOpen = false;
        await XlogDialog.ShowAsync();
    }

    private async void EditXlog_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: XlogProfile profile }) return;
        _editingXlog = profile.Id;
        XlogName.Text = profile.Name;
        XlogPattern.Text = profile.FilePattern;
        XlogKey.Password = "";
        XlogKey.Header = "新私钥（留空保持不变）";
        XlogSecretHint.Visibility = Visibility.Visible;
        XlogInfo.IsOpen = false;
        await XlogDialog.ShowAsync();
    }

    private async void XlogDialog_PrimaryButtonClick(
        ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            var name = XlogName.Text.Trim();
            var pattern = XlogPattern.Text.Trim();
            if (name.Length == 0 || pattern.Length == 0)
                throw new InvalidOperationException("方案名称和匹配文件名不能为空");
            if (_editingXlog is null && string.IsNullOrWhiteSpace(XlogKey.Password))
                throw new InvalidOperationException("新方案必须填写私钥");

            var id = _editingXlog ?? Guid.NewGuid();
            var profile = new XlogProfile(id, name, pattern);
            var index = _settings.Current.XlogProfiles.FindIndex(value => value.Id == id);
            if (index >= 0) _settings.Current.XlogProfiles[index] = profile;
            else _settings.Current.XlogProfiles.Add(profile);

            if (!string.IsNullOrWhiteSpace(XlogKey.Password))
            {
                var normalized = string.Concat(
                    XlogKey.Password.Where(value => !char.IsWhiteSpace(value)));
                if (normalized.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
                    normalized = normalized[2..];
                await _settings.SaveXlogPrivateKeyAsync(id, Convert.FromHexString(normalized));
            }
            else
            {
                await _settings.SaveAsync();
            }
            RefreshProfiles();
        }
        catch (Exception exception)
        {
            args.Cancel = true;
            ShowError(XlogInfo, exception.Message);
        }
        finally
        {
            deferral.Complete();
        }
    }

    private async void DeleteXlog_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: XlogProfile profile }) return;
        await _settings.RemoveXlogProfileAsync(profile.Id);
        RefreshProfiles();
    }

    private async void AddLogan_Click(object sender, RoutedEventArgs e)
    {
        _editingLogan = null;
        LoganName.Text = "默认环境";
        LoganPattern.Text = FilenamePatternDefaults.Logan;
        LoganKey.Password = "";
        LoganIV.Password = "";
        LoganSecretHint.Visibility = Visibility.Collapsed;
        LoganInfo.IsOpen = false;
        await LoganDialog.ShowAsync();
    }

    private async void EditLogan_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: LoganProfile profile }) return;
        _editingLogan = profile.Id;
        LoganName.Text = profile.Name;
        LoganPattern.Text = profile.FilePattern;
        LoganKey.Password = "";
        LoganIV.Password = "";
        LoganSecretHint.Visibility = Visibility.Visible;
        LoganInfo.IsOpen = false;
        await LoganDialog.ShowAsync();
    }

    private async void LoganDialog_PrimaryButtonClick(
        ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            var name = LoganName.Text.Trim();
            var pattern = LoganPattern.Text.Trim();
            if (name.Length == 0 || pattern.Length == 0)
                throw new InvalidOperationException("方案名称和匹配文件名不能为空");
            if (_editingLogan is null &&
                (LoganKey.Password.Length == 0 || LoganIV.Password.Length == 0))
                throw new InvalidOperationException("新方案必须填写 AES Key 和 IV");
            if ((LoganKey.Password.Length == 0) != (LoganIV.Password.Length == 0))
                throw new InvalidOperationException("AES Key 和 IV 必须同时填写或同时留空");

            var id = _editingLogan ?? Guid.NewGuid();
            var profile = new LoganProfile(id, name, pattern);
            var index = _settings.Current.LoganProfiles.FindIndex(value => value.Id == id);
            if (index >= 0) _settings.Current.LoganProfiles[index] = profile;
            else _settings.Current.LoganProfiles.Add(profile);

            if (LoganKey.Password.Length > 0)
            {
                await _settings.SaveLoganCredentialsAsync(
                    id,
                    Encoding.UTF8.GetBytes(LoganKey.Password),
                    Encoding.UTF8.GetBytes(LoganIV.Password));
            }
            else
            {
                await _settings.SaveAsync();
            }
            RefreshProfiles();
        }
        catch (Exception exception)
        {
            args.Cancel = true;
            ShowError(LoganInfo, exception.Message);
        }
        finally
        {
            deferral.Complete();
        }
    }

    private async void DeleteLogan_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: LoganProfile profile }) return;
        await _settings.RemoveLoganProfileAsync(profile.Id);
        RefreshProfiles();
    }

    private void RefreshFolders()
    {
        var folders = _settings.MonitoredFolders.ToArray();
        FolderList.ItemsSource = folders;
        FolderList.Visibility = folders.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyFolders.Visibility = folders.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RefreshProfiles()
    {
        var xlogProfiles = _settings.Current.XlogProfiles.ToArray();
        XlogProfileList.ItemsSource = xlogProfiles;
        XlogProfileList.Visibility = xlogProfiles.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyXlogProfiles.Visibility = xlogProfiles.Length > 0 ? Visibility.Collapsed : Visibility.Visible;

        var loganProfiles = _settings.Current.LoganProfiles.ToArray();
        LoganProfileList.ItemsSource = loganProfiles;
        LoganProfileList.Visibility = loganProfiles.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyLoganProfiles.Visibility = loganProfiles.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RefreshZipRules()
    {
        var canDelete = _settings.Current.ZipPatternRules.Count > 1;
        ZipRuleList.ItemsSource = _settings.Current.ZipPatternRules
            .Select(value => new ZipRulePresentation(value.Id, value.Pattern, canDelete))
            .ToArray();
    }

    private static void ShowError(InfoBar info, string message)
    {
        info.IsOpen = true;
        info.Severity = InfoBarSeverity.Error;
        info.Title = "操作失败";
        info.Message = message;
    }

    public sealed record ZipRulePresentation(Guid Id, string Pattern, bool CanDelete);
}
