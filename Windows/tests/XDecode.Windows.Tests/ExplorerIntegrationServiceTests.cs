using XDecode.WindowsApp;

namespace XDecode.Windows.Tests;

public sealed class ExplorerIntegrationServiceTests
{
    private const string ExecutablePath = @"C:\Program Files\XDecode\XDecode.Windows.exe";
    private const string IconPath = @"C:\Program Files\XDecode\Assets\XDecode.ico";

    [Fact]
    public void RegistersAfterNotepadWhenNotepadVerbExists()
    {
        var registry = new FakeExplorerIntegrationRegistry { NotepadVerbExists = true };
        var service = new ExplorerIntegrationService(registry, ExecutablePath, IconPath);

        Assert.True(service.EnsureRegistered());
        Assert.Equal([".xlog", ".mx", ".zip"], registry.DeletedExtensions);
        Assert.True(registry.NotifiedShellAssociationsChanged);
        Assert.Empty(registry.TopVerbs);
        var verb = Assert.Single(registry.VerbsAfterNotepad);
        Assert.Equal("使用 XDecode 解密", verb.Title);
        Assert.Equal(IconPath, verb.IconPath);
        Assert.Equal($"\"{ExecutablePath}\" --explorer \"%1\"", verb.Command);
        Assert.Equal(
            "System.FileExtension:=\".xlog\" OR " +
            "System.FileExtension:=\".mx\" OR " +
            "System.FileExtension:=\".zip\"",
            verb.AppliesTo);
    }

    [Fact]
    public void RegistersRequestedExtensionsAtTopWhenNotepadVerbIsMissing()
    {
        var registry = new FakeExplorerIntegrationRegistry();
        var service = new ExplorerIntegrationService(registry, ExecutablePath, IconPath);

        Assert.True(service.EnsureRegistered());
        Assert.Equal([".xlog", ".mx", ".zip"], registry.DeletedExtensions);
        Assert.Empty(registry.VerbsAfterNotepad);
        Assert.Equal([".xlog", ".mx", ".zip"], registry.TopVerbs.Select(value => value.Extension));
        Assert.All(registry.TopVerbs, value =>
        {
            Assert.Equal("使用 XDecode 解密", value.Title);
            Assert.Equal(IconPath, value.IconPath);
            Assert.Equal($"\"{ExecutablePath}\" --explorer \"%1\"", value.Command);
        });
    }

    [Fact]
    public void RegistryAccessFailureDoesNotPreventApplicationStartup()
    {
        var registry = new FakeExplorerIntegrationRegistry
        {
            SetException = new UnauthorizedAccessException(),
        };
        var service = new ExplorerIntegrationService(registry, ExecutablePath, IconPath);

        Assert.False(service.EnsureRegistered());
    }

    private sealed class FakeExplorerIntegrationRegistry : IExplorerIntegrationRegistry
    {
        public bool NotepadVerbExists { get; init; }
        public bool NotifiedShellAssociationsChanged { get; private set; }
        public Exception? SetException { get; init; }
        public List<string> DeletedExtensions { get; } = [];
        public List<VerbAfterNotepadRegistration> VerbsAfterNotepad { get; } = [];
        public List<TopVerbRegistration> TopVerbs { get; } = [];

        public bool HasNotepadVerb() => NotepadVerbExists;

        public void DeleteExistingVerbs(IEnumerable<string> extensions) =>
            DeletedExtensions.AddRange(extensions);

        public void SetVerbAfterNotepad(
            string title,
            string iconPath,
            string command,
            string appliesTo)
        {
            if (SetException is not null) throw SetException;
            VerbsAfterNotepad.Add(new(title, iconPath, command, appliesTo));
        }

        public void SetTopVerb(string extension, string title, string iconPath, string command)
        {
            if (SetException is not null) throw SetException;
            TopVerbs.Add(new(extension, title, iconPath, command));
        }

        public void NotifyShellAssociationsChanged() =>
            NotifiedShellAssociationsChanged = true;
    }

    private sealed record VerbAfterNotepadRegistration(
        string Title,
        string IconPath,
        string Command,
        string AppliesTo);

    private sealed record TopVerbRegistration(
        string Extension,
        string Title,
        string IconPath,
        string Command);
}
