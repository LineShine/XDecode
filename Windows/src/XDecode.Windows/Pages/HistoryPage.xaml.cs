using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDecode.Core;

namespace XDecode.WindowsApp.Pages;

public sealed partial class HistoryPage : Page
{
    public HistoryPage()
    {
        InitializeComponent();
        HistoryList.ItemsSource = App.CurrentApp.Services.RecentResults;
    }

    private async void Clear_Click(object sender, RoutedEventArgs e) =>
        await App.CurrentApp.Services.ClearHistoryAsync();

    private void Reveal_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: DecodeResult result }) return;
        var path = result.OutputPath ?? result.Request.SourcePath;
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")
        {
            UseShellExecute = true
        });
    }
}
