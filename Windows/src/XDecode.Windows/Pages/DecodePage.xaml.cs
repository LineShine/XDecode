using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using XDecode.Core;

namespace XDecode.WindowsApp.Pages;

public sealed partial class DecodePage : Page
{
    public DecodePage()
    {
        InitializeComponent();
        RecentList.ItemsSource = App.CurrentApp.Services.RecentResults;
    }

    private async void SelectFiles_Click(object sender, RoutedEventArgs e) =>
        await App.CurrentApp.Services.PickAndEnqueueAsync(App.CurrentApp.MainWindow);

    private void DropTarget_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
            e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void DropTarget_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        await App.CurrentApp.Services.EnqueueAsync(
            items.OfType<StorageFile>().Select(value => value.Path),
            DecodeOrigin.DragAndDrop);
    }

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
