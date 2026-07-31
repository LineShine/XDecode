using Microsoft.UI.Xaml.Data;
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
