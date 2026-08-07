using XDecode.Core;
using XDecode.WindowsApp;

namespace XDecode.Windows.Tests;

public sealed class SingleInstanceCoordinatorTests
{
    [Fact]
    public async Task SecondaryInstanceForwardsActivationToPrimary()
    {
        var scope = $"XDecode-Test-{Guid.NewGuid():N}";
        await using var primary = new SingleInstanceCoordinator(scope);
        await using var secondary = new SingleInstanceCoordinator(scope);
        Assert.True(primary.IsPrimary);
        Assert.False(secondary.IsPrimary);

        var completion = new TaskCompletionSource<InstanceActivation>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        primary.ActivationReceived += completion.SetResult;
        primary.StartListening();

        var expected = new InstanceActivation(
            true,
            DecodeOrigin.OpenWith,
            [@"C:\logs\sample.xlog"]);
        Assert.True(await secondary.ForwardAsync(
            expected,
            TestContext.Current.CancellationToken));

        var actual = await completion.Task.WaitAsync(
            TimeSpan.FromSeconds(5),
            TestContext.Current.CancellationToken);
        Assert.Equal(expected.ShowWindow, actual.ShowWindow);
        Assert.Equal(expected.Origin, actual.Origin);
        Assert.Equal(expected.Paths, actual.Paths);
    }
}
