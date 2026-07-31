using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace XDecode.WindowsApp.Pages;

public sealed partial class MonitorPage : Page
{
    private bool _loading = true;

    public MonitorPage()
    {
        InitializeComponent();
        AutomaticToggle.IsOn = App.CurrentApp.Services.Settings.Current.AutomaticEnabled;
        RefreshFolders();
        _loading = false;
    }

    private async void AutomaticToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        App.CurrentApp.Services.Settings.Current.AutomaticEnabled = AutomaticToggle.IsOn;
        await App.CurrentApp.Services.ReloadMonitoringAsync();
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var path = await App.CurrentApp.Services.PickFolderAsync(App.CurrentApp.MainWindow);
        if (path is null) return;
        await App.CurrentApp.Services.Settings.AddMonitoredFolderAsync(path);
        await App.CurrentApp.Services.ReloadMonitoringAsync();
        RefreshFolders();
    }

    private async void RemoveFolder_Click(object sender, RoutedEventArgs e)
    {
        if (FolderList.SelectedItem is not string path) return;
        await App.CurrentApp.Services.Settings.RemoveMonitoredFolderAsync(path);
        await App.CurrentApp.Services.ReloadMonitoringAsync();
        RefreshFolders();
    }

    private void RefreshFolders() =>
        FolderList.ItemsSource = App.CurrentApp.Services.Settings.MonitoredFolders.ToArray();
}
