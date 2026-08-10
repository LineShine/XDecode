using XDecode.WindowsApp;

namespace XDecode.Windows.Tests;

public sealed class StartupServiceTests
{
    private const string ExecutablePath = @"C:\Program Files\XDecode\XDecode.Windows.exe";

    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData("   ", false)]
    [InlineData("XDecode.Windows.exe --startup", true)]
    public async Task StateReflectsRunEntry(string? value, bool expected)
    {
        var registry = new FakeStartupRegistry { Value = value };
        var service = new StartupService(registry, ExecutablePath);

        Assert.Equal(expected, await service.GetStateAsync());
    }

    [Fact]
    public async Task EnablingWritesStartupCommand()
    {
        var registry = new FakeStartupRegistry();
        var service = new StartupService(registry, ExecutablePath);

        Assert.True(await service.SetEnabledAsync(true));
        Assert.Equal($"\"{ExecutablePath}\" --startup", registry.Value);
    }

    [Fact]
    public async Task DisablingDeletesRunEntry()
    {
        var registry = new FakeStartupRegistry { Value = "existing command" };
        var service = new StartupService(registry, ExecutablePath);

        Assert.False(await service.SetEnabledAsync(false));
        Assert.Null(registry.Value);
    }

    [Fact]
    public async Task FailedDisableStillReportsExistingEntry()
    {
        var registry = new FakeStartupRegistry
        {
            Value = "existing command",
            DeleteException = new UnauthorizedAccessException(),
        };
        var service = new StartupService(registry, ExecutablePath);

        Assert.True(await service.SetEnabledAsync(false));
    }

    [Fact]
    public async Task FailedEnableStillReportsMissingEntry()
    {
        var registry = new FakeStartupRegistry
        {
            SetException = new UnauthorizedAccessException(),
        };
        var service = new StartupService(registry, ExecutablePath);

        Assert.False(await service.SetEnabledAsync(true));
    }

    [Fact]
    public async Task RegistryReadFailureReportsDisabled()
    {
        var registry = new FakeStartupRegistry
        {
            GetException = new UnauthorizedAccessException(),
        };
        var service = new StartupService(registry, ExecutablePath);

        Assert.False(await service.GetStateAsync());
    }

    private sealed class FakeStartupRegistry : IStartupRegistry
    {
        public string? Value { get; set; }
        public Exception? GetException { get; init; }
        public Exception? SetException { get; init; }
        public Exception? DeleteException { get; init; }

        public string? GetValue()
        {
            if (GetException is not null) throw GetException;
            return Value;
        }

        public void SetValue(string command)
        {
            if (SetException is not null) throw SetException;
            Value = command;
        }

        public void DeleteValue()
        {
            if (DeleteException is not null) throw DeleteException;
            Value = null;
        }
    }
}
