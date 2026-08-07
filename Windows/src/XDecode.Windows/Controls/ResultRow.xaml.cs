using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDecode.Core;

namespace XDecode.WindowsApp.Controls;

public sealed partial class ResultRow : UserControl
{
    public static readonly DependencyProperty ResultProperty = DependencyProperty.Register(
        nameof(Result), typeof(DecodeResult), typeof(ResultRow), new PropertyMetadata(null));

    public DecodeResult? Result
    {
        get => (DecodeResult?)GetValue(ResultProperty);
        set => SetValue(ResultProperty, value);
    }

    public ResultRow() => InitializeComponent();

    private void Reveal_Click(object sender, RoutedEventArgs e)
    {
        if (Result is not { } result) return;
        var path = result.OutputPath ?? result.Request.SourcePath;
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")
        {
            UseShellExecute = true
        });
    }
}
