using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed class DecodeStateConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is DecodeState state ? state switch
        {
            DecodeState.Completed => "成功",
            DecodeState.PartiallyCompleted => "部分成功",
            DecodeState.CompletedWithWarning => "成功但有警告",
            DecodeState.Skipped => "已跳过",
            _ => "失败"
        } : "";

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

public sealed class DecodeStateSymbolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is DecodeState state ? state switch
        {
            DecodeState.Completed => Symbol.Accept,
            DecodeState.PartiallyCompleted => Symbol.Important,
            DecodeState.CompletedWithWarning => Symbol.Important,
            DecodeState.Skipped => Symbol.Remove,
            _ => Symbol.Cancel
        } : Symbol.Help;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

public sealed class DecodeStateBrushConverter : IValueConverter
{
    private static readonly Brush Success = new SolidColorBrush(Color.FromArgb(255, 22, 132, 71));
    private static readonly Brush Warning = new SolidColorBrush(Color.FromArgb(255, 196, 98, 0));
    private static readonly Brush Failure = new SolidColorBrush(Color.FromArgb(255, 196, 43, 28));
    private static readonly Brush Secondary = new SolidColorBrush(Color.FromArgb(255, 112, 112, 112));

    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is DecodeState state ? state switch
        {
            DecodeState.Completed => Success,
            DecodeState.PartiallyCompleted => Warning,
            DecodeState.CompletedWithWarning => Warning,
            DecodeState.Skipped => Secondary,
            _ => Failure
        } : Secondary;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

public sealed class FileNameConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is string path ? Path.GetFileName(path) : "";

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

public sealed class DecodeDurationTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is DecodeResult result
            ? $"耗时 {DurationMilliseconds(result)} ms"
            : "";

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();

    internal static int DurationMilliseconds(DecodeResult result)
    {
        var value = (result.FinishedAt - result.Request.RequestedAt).TotalMilliseconds;
        return double.IsFinite(value) && value > 0 ? (int)Math.Round(value) : 0;
    }
}

public sealed class DecodeDurationBrushConverter : IValueConverter
{
    private static readonly Brush Fast = new SolidColorBrush(Color.FromArgb(255, 22, 132, 71));
    private static readonly Brush Warning = new SolidColorBrush(Color.FromArgb(255, 196, 98, 0));
    private static readonly Brush Slow = new SolidColorBrush(Color.FromArgb(255, 196, 43, 28));

    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is not DecodeResult result) return Fast;
        var milliseconds = DecodeDurationTextConverter.DurationMilliseconds(result);
        return milliseconds < 1_000 ? Fast : milliseconds <= 3_000 ? Warning : Slow;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

public sealed class LogFormatConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is LogFormat format ? format switch
        {
            LogFormat.Mx => "MX",
            LogFormat.Zip => "ZIP",
            LogFormat.Xlog => "Xlog",
            _ => "Logan"
        } : "";

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
