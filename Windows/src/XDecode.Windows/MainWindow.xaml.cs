using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WinRT.Interop;

namespace XDecode.WindowsApp;

public sealed partial class MainWindow : Window
{
    private bool _isExiting;
    private readonly AppWindow _appWindow;

    public MainWindow()
    {
        StartupTrace.Write("MainWindow: InitializeComponent begin");
        InitializeComponent();
        StartupTrace.Write("MainWindow: InitializeComponent complete");
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        _appWindow = AppWindow.GetFromWindowId(id);
        _appWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "XDecode.ico"));
        StartupTrace.Write("MainWindow: AppWindow acquired");
        _appWindow.Resize(new Windows.Graphics.SizeInt32(1080, 720));
        _appWindow.Closing += OnClosing;
        Navigation.SelectedItem = Navigation.MenuItems[0];
        RefreshAutomationStatus();
        NavigateTo("decode", activate: false);
        StartupTrace.Write("MainWindow: complete");
    }

    public void ShowAndActivate()
    {
        _appWindow.Show();
        Activate();
    }

    public void Hide() => _appWindow.Hide();

    public void RefreshAutomationStatus()
    {
        var enabled = App.CurrentApp.Services.Settings.Current.AutomaticEnabled;
        AutomationStatusDot.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        AutomationStatusText.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
    }

    public void NavigateTo(string tag) => NavigateTo(tag, activate: true);

    private void NavigateTo(string tag, bool activate)
    {
        var page = tag switch
        {
            "history" => typeof(Pages.HistoryPage),
            "monitor" => typeof(Pages.MonitorPage),
            "explorer" => typeof(Pages.ExplorerIntegrationPage),
            "settings" => typeof(Pages.SettingsPage),
            _ => typeof(Pages.DecodePage)
        };
        if (ContentFrame.CurrentSourcePageType != page) ContentFrame.Navigate(page);
        Navigation.SelectedItem = Navigation.MenuItems
            .OfType<NavigationViewItem>()
            .FirstOrDefault(value => Equals(value.Tag, tag));
        if (activate) ShowAndActivate();
    }

    public async void ExitApplication()
    {
        _isExiting = true;
        try { await App.CurrentApp.ShutdownAsync(); }
        finally
        {
            Close();
            App.CurrentApp.Exit();
        }
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs arguments)
    {
        if (_isExiting) return;
        arguments.Cancel = true;
        sender.Hide();
    }

    private void Navigation_SelectionChanged(
        NavigationView sender, NavigationViewSelectionChangedEventArgs arguments)
    {
        if (arguments.SelectedItemContainer?.Tag is string tag) NavigateTo(tag, activate: false);
    }

    private async void AddLogs_Click(object sender, RoutedEventArgs e) =>
        await App.CurrentApp.Services.PickAndEnqueueAsync(this);
}
