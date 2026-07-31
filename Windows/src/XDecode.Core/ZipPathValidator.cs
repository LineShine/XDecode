using System.Buffers;
using System.Text.RegularExpressions;

namespace XDecode.Core;

public static partial class ZipPathValidator
{
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    };
    private static readonly SearchValues<char> InvalidCharacters = SearchValues.Create("<>:\"|?*");

    public static string ValidateRelativePath(string rawPath)
    {
        if (string.IsNullOrEmpty(rawPath) || rawPath.Contains('\0', StringComparison.Ordinal) ||
            rawPath.StartsWith('/') || rawPath.StartsWith('\\') ||
            rawPath.StartsWith("//", StringComparison.Ordinal) ||
            rawPath.StartsWith(@"\\", StringComparison.Ordinal) ||
            DrivePath().IsMatch(rawPath))
            throw DecodeException.DecodingFailed($"ZIP 包含不安全路径：{rawPath}");

        var normalized = rawPath.Replace('\\', '/');
        var safeComponents = new List<string>();
        foreach (var component in normalized.Split('/', StringSplitOptions.None))
        {
            if (component is "" or ".") continue;
            if (component == "..")
                throw DecodeException.DecodingFailed($"ZIP 包含路径穿越条目：{rawPath}");
            if (component.Any(character => character < ' ') ||
                component.AsSpan().ContainsAny(InvalidCharacters) ||
                component.EndsWith(' ') || component.EndsWith('.') ||
                IsDeviceName(component))
                throw DecodeException.DecodingFailed($"ZIP 包含 Windows 不安全路径：{rawPath}");
            safeComponents.Add(component);
        }
        if (safeComponents.Count == 0)
            throw DecodeException.DecodingFailed($"ZIP 包含不安全路径：{rawPath}");
        return string.Join('/', safeComponents);
    }

    public static bool IsMetadataPath(string relativePath)
    {
        var components = relativePath.Split('/');
        return components.Any(value => value.Equals("__MACOSX", StringComparison.Ordinal)) ||
            components[^1].StartsWith("._", StringComparison.Ordinal);
    }

    private static bool IsDeviceName(string component)
    {
        var trimmed = component.TrimEnd(' ', '.');
        var baseName = trimmed.Split('.', 2)[0];
        return ReservedNames.Contains(baseName);
    }

    [GeneratedRegex(@"^[A-Za-z]:", RegexOptions.CultureInvariant)]
    private static partial Regex DrivePath();
}
