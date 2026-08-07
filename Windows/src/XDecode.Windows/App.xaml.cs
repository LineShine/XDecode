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
    private SingleInstanceCoordinator? _singleInstance;
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
            var activatedArguments = current.GetActivatedEventArgs();
            _singleInstance = new SingleInstanceCoordinator();
            StartupTrace.Write($"OnLaunched: primary instance={_singleInstance.IsPrimary}");
            if (!_singleInstance.IsPrimary)
            {
                var activation = ParseActivation(activatedArguments, initial: false);
                if (!await _singleInstance.ForwardAsync(activation))
                    StartupTrace.Write("OnLaunched: failed to forward activation to primary instance");
                await _singleInstance.DisposeAsync();
                _singleInstance = null;
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
            await _services.InitializeAsync(_window);
            StartupTrace.Write("OnLaunched: services initialized");
            _singleInstance.ActivationReceived += OnInstanceActivation;
            _singleInstance.StartListening();
            await ApplyActivationAsync(ParseActivation(activatedArguments, initial: true));
            StartupTrace.Write("OnLaunched: complete");
        }
        catch (Exception exception)
        {
            StartupTrace.Write($"OnLaunched failed: {exception}");
            try { await ShutdownAsync(); }
            catch (Exception shutdownException)
            {
                StartupTrace.Write($"Shutdown after launch failure failed: {shutdownException}");
            }
            Exit();
        }
    }

    private void OnInstanceActivation(InstanceActivation activation)
    {
        _window?.DispatcherQueue.TryEnqueue(
            DispatcherQueuePriority.Normal,
            () => _ = ApplyActivationAsync(activation));
    }

    private static InstanceActivation ParseActivation(AppActivationArguments arguments, bool initial)
    {
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
        return new InstanceActivation(showWindow, origin, paths.ToArray());
    }

    private async Task ApplyActivationAsync(InstanceActivation activation)
    {
        if (_window is null || _services is null) return;
        if (activation.ShowWindow == true) _window.ShowAndActivate();
        else if (activation.ShowWindow == false) _window.Hide();
        if (activation.Paths.Length > 0)
            await _services.EnqueueAsync(activation.Paths, activation.Origin);
    }

    public async Task ShutdownAsync()
    {
        var services = _services;
        _services = null;
        try
        {
            if (services is not null) await services.DisposeAsync();
        }
        finally
        {
            var singleInstance = _singleInstance;
            _singleInstance = null;
            if (singleInstance is not null)
            {
                singleInstance.ActivationReceived -= OnInstanceActivation;
                await singleInstance.DisposeAsync();
            }
        }
    }
}
