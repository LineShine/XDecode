using System.Diagnostics;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel;
using XDecode.Application;

namespace XDecode.WindowsApp.Pages;

public sealed partial class SettingsPage : Page
{
    private readonly SettingsStore _settings = App.CurrentApp.Services.Settings;
    private bool _loading = true;
    private Guid? _editingXlog;
    private Guid? _editingLogan;

    public SettingsPage()
    {
        InitializeComponent();
        NotificationToggle.IsOn = _settings.Current.NotificationsEnabled;
        MxPattern.Text = _settings.Current.MxFilePattern;
        RefreshProfiles();
        RefreshZipRules();
        _ = LoadStartupStateAsync();
        _loading = false;
    }

    private async Task LoadStartupStateAsync()
    {
        var state = await App.CurrentApp.Services.Startup.GetStateAsync();
        _loading = true;
        StartupToggle.IsOn = state == StartupTaskState.Enabled;
        _loading = false;
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
        if (StartupToggle.IsOn != enabled)
        {
            _loading = true;
            StartupToggle.IsOn = enabled;
            _loading = false;
        }
    }

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            var result = await new UpdateChecker(client).CheckAsync("1.0.0");
            UpdateInfo.IsOpen = true;
            UpdateInfo.Severity = result.IsUpdateAvailable
                ? InfoBarSeverity.Informational : InfoBarSeverity.Success;
            UpdateInfo.Title = result.IsUpdateAvailable ? "发现新版本" : "当前已是最新版本";
            UpdateInfo.Message = result.Release.Version;
            if (result.IsUpdateAvailable)
            {
                Process.Start(new ProcessStartInfo(result.Release.PageUri.AbsoluteUri)
                {
                    UseShellExecute = true
                });
            }
        }
        catch (Exception exception)
        {
            ShowError(UpdateInfo, exception.Message);
        }
    }

    private void AddXlog_Click(object sender, RoutedEventArgs e)
    {
        _editingXlog = null;
        XlogProfileList.SelectedItem = null;
        XlogName.Text = "";
        XlogPattern.Text = FilenamePatternDefaults.Xlog;
        XlogKey.Password = "";
    }

    private async void SaveXlog_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var id = _editingXlog ?? Guid.NewGuid();
            var profile = new XlogProfile(id, XlogName.Text.Trim(), XlogPattern.Text.Trim());
            var index = _settings.Current.XlogProfiles.FindIndex(value => value.Id == id);
            if (index >= 0) _settings.Current.XlogProfiles[index] = profile;
            else _settings.Current.XlogProfiles.Add(profile);
            if (!string.IsNullOrWhiteSpace(XlogKey.Password))
                await _settings.SaveXlogPrivateKeyAsync(id, Convert.FromHexString(
                    string.Concat(XlogKey.Password.Where(value => !char.IsWhiteSpace(value)))
                        .Replace("0x", "", StringComparison.OrdinalIgnoreCase)));
            else
                await _settings.SaveAsync();
            _editingXlog = id;
            XlogKey.Password = "";
            RefreshProfiles();
            ShowSuccess(XlogInfo, "已保存");
        }
        catch (Exception exception) { ShowError(XlogInfo, exception.Message); }
    }

    private async void DeleteXlog_Click(object sender, RoutedEventArgs e)
    {
        if (_editingXlog is not { } id) return;
        await _settings.RemoveXlogProfileAsync(id);
        AddXlog_Click(sender, e);
        RefreshProfiles();
    }

    private void XlogProfileList_SelectionChanged(
        object sender, SelectionChangedEventArgs e)
    {
        if (XlogProfileList.SelectedItem is not XlogProfile profile) return;
        _editingXlog = profile.Id;
        XlogName.Text = profile.Name;
        XlogPattern.Text = profile.FilePattern;
        XlogKey.Password = "";
    }

    private void AddLogan_Click(object sender, RoutedEventArgs e)
    {
        _editingLogan = null;
        LoganProfileList.SelectedItem = null;
        LoganName.Text = "";
        LoganPattern.Text = FilenamePatternDefaults.Logan;
        LoganKey.Password = "";
        LoganIV.Password = "";
    }

    private async void SaveLogan_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var id = _editingLogan ?? Guid.NewGuid();
            var profile = new LoganProfile(id, LoganName.Text.Trim(), LoganPattern.Text.Trim());
            var index = _settings.Current.LoganProfiles.FindIndex(value => value.Id == id);
            if (index >= 0) _settings.Current.LoganProfiles[index] = profile;
            else _settings.Current.LoganProfiles.Add(profile);
            if (LoganKey.Password.Length > 0 || LoganIV.Password.Length > 0)
            {
                await _settings.SaveLoganCredentialsAsync(
                    id, Encoding.UTF8.GetBytes(LoganKey.Password), Encoding.UTF8.GetBytes(LoganIV.Password));
            }
            else
            {
                await _settings.SaveAsync();
            }
            _editingLogan = id;
            LoganKey.Password = "";
            LoganIV.Password = "";
            RefreshProfiles();
            ShowSuccess(LoganInfo, "已保存");
        }
        catch (Exception exception) { ShowError(LoganInfo, exception.Message); }
    }

    private async void DeleteLogan_Click(object sender, RoutedEventArgs e)
    {
        if (_editingLogan is not { } id) return;
        await _settings.RemoveLoganProfileAsync(id);
        AddLogan_Click(sender, e);
        RefreshProfiles();
    }

    private void LoganProfileList_SelectionChanged(
        object sender, SelectionChangedEventArgs e)
    {
        if (LoganProfileList.SelectedItem is not LoganProfile profile) return;
        _editingLogan = profile.Id;
        LoganName.Text = profile.Name;
        LoganPattern.Text = profile.FilePattern;
        LoganKey.Password = "";
        LoganIV.Password = "";
    }

    private void AddZipRule_Click(object sender, RoutedEventArgs e)
    {
        var rule = new ZipPatternRule(Guid.NewGuid(), "");
        _settings.Current.ZipPatternRules.Add(rule);
        RefreshZipRules();
        ZipRuleList.SelectedItem = rule;
        ZipPattern.Text = "";
    }

    private async void SaveRules_Click(object sender, RoutedEventArgs e)
    {
        _settings.Current.MxFilePattern = MxPattern.Text.Trim();
        if (ZipRuleList.SelectedItem is ZipPatternRule rule)
        {
            var index = _settings.Current.ZipPatternRules.FindIndex(value => value.Id == rule.Id);
            if (index >= 0)
                _settings.Current.ZipPatternRules[index] = rule with { Pattern = ZipPattern.Text.Trim() };
        }
        await _settings.SaveAsync();
        RefreshZipRules();
    }

    private async void DeleteZipRule_Click(object sender, RoutedEventArgs e)
    {
        if (ZipRuleList.SelectedItem is not ZipPatternRule rule) return;
        _settings.Current.ZipPatternRules.RemoveAll(value => value.Id == rule.Id);
        if (_settings.Current.ZipPatternRules.Count == 0)
            _settings.Current.ZipPatternRules.Add(new(Guid.NewGuid(), FilenamePatternDefaults.Zip));
        await _settings.SaveAsync();
        RefreshZipRules();
    }

    private void RefreshProfiles()
    {
        XlogProfileList.ItemsSource = null;
        XlogProfileList.ItemsSource = _settings.Current.XlogProfiles.ToArray();
        LoganProfileList.ItemsSource = null;
        LoganProfileList.ItemsSource = _settings.Current.LoganProfiles.ToArray();
    }

    private void RefreshZipRules()
    {
        ZipRuleList.ItemsSource = null;
        ZipRuleList.ItemsSource = _settings.Current.ZipPatternRules.ToArray();
        ZipRuleList.SelectionChanged -= ZipRuleList_SelectionChanged;
        ZipRuleList.SelectionChanged += ZipRuleList_SelectionChanged;
    }

    private void ZipRuleList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ZipRuleList.SelectedItem is ZipPatternRule rule) ZipPattern.Text = rule.Pattern;
    }

    private static void ShowError(InfoBar info, string message)
    {
        info.IsOpen = true;
        info.Severity = InfoBarSeverity.Error;
        info.Title = "操作失败";
        info.Message = message;
    }

    private static void ShowSuccess(InfoBar info, string message)
    {
        info.IsOpen = true;
        info.Severity = InfoBarSeverity.Success;
        info.Title = message;
        info.Message = "";
    }
}
