namespace XDecode.WindowsApp;

internal static class StartupTrace
{
    private const string EnvironmentVariable = "XDECODE_STARTUP_TRACE";

    public static void Write(string message)
    {
        var path = Environment.GetEnvironmentVariable(EnvironmentVariable);
        if (string.IsNullOrWhiteSpace(path)) return;

        try
        {
            File.AppendAllText(
                path,
                $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }
        catch (Exception)
        {
            // Startup tracing is diagnostic-only and must never affect the app.
        }
    }
}
