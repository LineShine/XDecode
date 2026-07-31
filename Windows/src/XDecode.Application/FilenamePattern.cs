using System.Text;
using System.Text.RegularExpressions;

namespace XDecode.Application;

public static class FilenamePatternDefaults
{
    public const string Xlog = "*.xlog";
    public const string Logan = "yyyy-MM-dd";
    public const string Mx = "*.mx";
    public const string Zip = @"^[A-Za-z0-9_-]*[A-Za-z0-9][_-][A-Za-z0-9][A-Za-z0-9_-]*\.zip$";
}

public static class FilenamePattern
{
    public static bool Matches(string pattern, string path)
    {
        var trimmed = pattern.Trim();
        if (trimmed.Length == 0) return false;
        var expression = trimmed.StartsWith('^') ? trimmed : $"^{FriendlyExpression(trimmed)}$";
        try
        {
            return Regex.IsMatch(
                Path.GetFileName(path), expression,
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
                TimeSpan.FromSeconds(1));
        }
        catch (ArgumentException) { return false; }
        catch (RegexMatchTimeoutException) { return false; }
    }

    private static string FriendlyExpression(string pattern)
    {
        var result = new StringBuilder();
        for (var index = 0; index < pattern.Length;)
        {
            var remainder = pattern.AsSpan(index);
            if (remainder.StartsWith("yyyy", StringComparison.Ordinal))
            {
                result.Append(@"\d{4}");
                index += 4;
            }
            else if (remainder.StartsWith("MM", StringComparison.Ordinal) ||
                     remainder.StartsWith("dd", StringComparison.Ordinal))
            {
                result.Append(@"\d{2}");
                index += 2;
            }
            else
            {
                var character = pattern[index++];
                result.Append(character switch
                {
                    '*' => ".*",
                    '?' => ".",
                    _ => Regex.Escape(character.ToString())
                });
            }
        }
        return result.ToString();
    }
}
