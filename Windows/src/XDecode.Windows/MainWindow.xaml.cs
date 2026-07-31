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
        InitializeComponent();
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        _appWindow = AppWindow.GetFromWindowId(id);
        _appWindow.Resize(new Windows.Graphics.SizeInt32(1080, 720));
        _appWindow.Closing += OnClosing;
        Navigation.SelectedItem = Navigation.MenuItems[0];
        NavigateTo("decode", activate: false);
    }

    public void ShowAndActivate()
    {
        _appWindow.Show();
        Activate();
    }

    public void Hide() => _appWindow.Hide();

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
        await App.CurrentApp.Services.DisposeAsync();
        Close();
        App.CurrentApp.Exit();
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
}
