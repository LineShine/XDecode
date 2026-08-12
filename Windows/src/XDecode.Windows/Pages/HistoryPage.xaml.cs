using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDecode.Core;

namespace XDecode.WindowsApp.Pages;

public sealed partial class HistoryPage : Page
{
    private readonly ObservableCollection<DecodeResult> _results;
    private bool _subscribed;

    public HistoryPage()
    {
        InitializeComponent();
        _results = App.CurrentApp.Services.RecentResults;
        HistoryList.ItemsSource = _results;
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed)
        {
            _results.CollectionChanged += Results_CollectionChanged;
            _subscribed = true;
        }
        RefreshEmptyState();
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed) return;
        _results.CollectionChanged -= Results_CollectionChanged;
        _subscribed = false;
    }

    private void Results_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) =>
        RefreshEmptyState();

    private void RefreshEmptyState()
    {
        var hasResults = _results.Count > 0;
        HistoryList.Visibility = hasResults ? Visibility.Visible : Visibility.Collapsed;
        EmptyHistory.Visibility = hasResults ? Visibility.Collapsed : Visibility.Visible;
        ClearButton.IsEnabled = hasResults;
    }

    private async void Clear_Click(object sender, RoutedEventArgs e) =>
        await App.CurrentApp.Services.ClearHistoryAsync();
}
