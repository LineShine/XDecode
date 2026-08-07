using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;
using XDecode.Core;

namespace XDecode.WindowsApp;

public partial class App : Microsoft.UI.Xaml.Application
{
    private MainWindow? _window;
    private AppServices? _services;
    public static App CurrentApp => (App)Current;
    public AppServices Services => _services ?? throw new InvalidOperationException("应用尚未初始化");
    public MainWindow MainWindow => _window ?? throw new InvalidOperationException("主窗口尚未初始化");

    public App()
    {
        StartupTrace.Write("App constructor: begin");
        InitializeComponent();
        UnhandledException += (_, arguments) =>
            StartupTrace.Write($"Unhandled exception: {arguments.Exception}");
        StartupTrace.Write("App constructor: complete");
    }

    protected override async void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        StartupTrace.Write("OnLaunched: begin");
        try
        {
            var current = AppInstance.GetCurrent();
            var main = AppInstance.FindOrRegisterForKey("XDecode.Main");
            StartupTrace.Write($"OnLaunched: app instance ready, current={main.IsCurrent}");
            if (!main.IsCurrent)
            {
                await main.RedirectActivationToAsync(current.GetActivatedEventArgs());
                Exit();
                return;
            }

            var localState = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LineShine",
                "XDecode");
            StartupTrace.Write("OnLaunched: creating services");
            _services = new AppServices(localState);
            StartupTrace.Write("OnLaunched: creating main window");
            _window = new MainWindow();
            StartupTrace.Write("OnLaunched: main window created");
            main.Activated += OnActivated;
            await _services.InitializeAsync(_window);
            StartupTrace.Write("OnLaunched: services initialized");
            await HandleActivationAsync(current.GetActivatedEventArgs(), initial: true);
            StartupTrace.Write("OnLaunched: complete");
        }
        catch (Exception exception)
        {
            StartupTrace.Write($"OnLaunched failed: {exception}");
            throw;
        }
    }

    private void OnActivated(object? sender, AppActivationArguments arguments)
    {
        _window?.DispatcherQueue.TryEnqueue(
            DispatcherQueuePriority.Normal,
            () => _ = HandleActivationAsync(arguments, initial: false));
    }

    private async Task HandleActivationAsync(AppActivationArguments arguments, bool initial)
    {
        if (_window is null || _services is null) return;
        var paths = new List<string>();
        var origin = DecodeOrigin.OpenWith;
        bool? showWindow = initial ? true : null;
        switch (arguments.Kind)
        {
            case ExtendedActivationKind.StartupTask:
                showWindow = initial ? false : null;
                origin = DecodeOrigin.Automatic;
                break;
            case ExtendedActivationKind.File:
                showWindow = initial ? false : null;
                if (arguments.Data is IFileActivatedEventArgs files)
                    paths.AddRange(files.Files.Select(value => value.Path).Where(value => !string.IsNullOrEmpty(value)));
                break;
            case ExtendedActivationKind.Launch:
                var launch = (ILaunchActivatedEventArgs)arguments.Data;
                var parsed = ActivationParser.Parse(launch.Arguments);
                paths.AddRange(parsed.Paths);
                showWindow = parsed.ShowWindow ? true : initial ? false : null;
                origin = parsed.Origin;
                break;
        }
        if (showWindow == true) _window.ShowAndActivate();
        else if (showWindow == false) _window.Hide();
        if (paths.Count > 0)
            await _services.EnqueueAsync(paths, origin);
    }
}
