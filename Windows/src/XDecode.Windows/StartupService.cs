using Windows.ApplicationModel;

namespace XDecode.WindowsApp;

public sealed class StartupService
{
    public async Task<StartupTaskState> GetStateAsync()
    {
        var task = await StartupTask.GetAsync("XDecodeStartup");
        return task.State;
    }

    public async Task<bool> SetEnabledAsync(bool enabled)
    {
        var task = await StartupTask.GetAsync("XDecodeStartup");
        if (!enabled)
        {
            task.Disable();
            return false;
        }
        if (task.State == StartupTaskState.Enabled) return true;
        var state = await task.RequestEnableAsync();
        return state == StartupTaskState.Enabled;
    }
}
