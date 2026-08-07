using System.Collections.Specialized;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace XDecode.WindowsApp.Pages;

public sealed partial class HistoryPage : Page
{
    private bool _subscribed;

    public HistoryPage()
    {
        InitializeComponent();
        HistoryList.ItemsSource = App.CurrentApp.Services.RecentResults;
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed)
        {
            App.CurrentApp.Services.RecentResults.CollectionChanged += Results_CollectionChanged;
            _subscribed = true;
        }
        RefreshEmptyState();
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed) return;
        App.CurrentApp.Services.RecentResults.CollectionChanged -= Results_CollectionChanged;
        _subscribed = false;
    }

    private void Results_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) =>
        RefreshEmptyState();

    private void RefreshEmptyState()
    {
        var hasResults = App.CurrentApp.Services.RecentResults.Count > 0;
        HistoryList.Visibility = hasResults ? Visibility.Visible : Visibility.Collapsed;
        EmptyHistory.Visibility = hasResults ? Visibility.Collapsed : Visibility.Visible;
        ClearButton.IsEnabled = hasResults;
    }

    private async void Clear_Click(object sender, RoutedEventArgs e) =>
        await App.CurrentApp.Services.ClearHistoryAsync();
}
