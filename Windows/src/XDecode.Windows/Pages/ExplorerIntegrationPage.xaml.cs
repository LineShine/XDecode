using Microsoft.UI.Xaml.Controls;

namespace XDecode.WindowsApp.Pages;

public sealed partial class ExplorerIntegrationPage : Page
{
    public IReadOnlyList<string> Associations { get; } = [".xlog", ".mx", ".logan", ".zip"];
    public ExplorerIntegrationPage() => InitializeComponent();
}
