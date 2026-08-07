using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using XDecode.Core;

namespace XDecode.WindowsApp.Pages;

public sealed partial class DecodePage : Page
{
    private readonly ObservableCollection<DecodeResult> _recent = [];
    private bool _subscribed;

    public DecodePage()
    {
        InitializeComponent();
        RecentList.ItemsSource = _recent;
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed)
        {
            App.CurrentApp.Services.RecentResults.CollectionChanged += Results_CollectionChanged;
            _subscribed = true;
        }
        RefreshResults();
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed) return;
        App.CurrentApp.Services.RecentResults.CollectionChanged -= Results_CollectionChanged;
        _subscribed = false;
    }

    private void Results_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) =>
        RefreshResults();

    private void RefreshResults()
    {
        _recent.Clear();
        foreach (var result in App.CurrentApp.Services.RecentResults.Take(5))
            _recent.Add(result);
        var hasResults = _recent.Count > 0;
        RecentList.Visibility = hasResults ? Visibility.Visible : Visibility.Collapsed;
        EmptyRecent.Visibility = hasResults ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void SelectFiles_Click(object sender, RoutedEventArgs e) =>
        await App.CurrentApp.Services.PickAndEnqueueAsync(App.CurrentApp.MainWindow);

    private void ViewAll_Click(object sender, RoutedEventArgs e) =>
        App.CurrentApp.MainWindow.NavigateTo("history");

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
}
