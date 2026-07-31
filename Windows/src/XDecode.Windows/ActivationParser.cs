using XDecode.Core;

namespace XDecode.WindowsApp;

public sealed record ParsedActivation(
    bool ShowWindow,
    DecodeOrigin Origin,
    IReadOnlyList<string> Paths);

public static class ActivationParser
{
    public static ParsedActivation Parse(string arguments)
    {
        var tokens = CommandLineToArgs(arguments);
        var background = false;
        var origin = DecodeOrigin.OpenWith;
        var paths = new List<string>();
        foreach (var token in tokens)
        {
            if (token == "--startup")
            {
                background = true;
                origin = DecodeOrigin.Automatic;
                continue;
            }
            if (token == "--explorer")
            {
                background = true;
                origin = DecodeOrigin.Explorer;
                continue;
            }
            if (token == "--open-with")
            {
                background = true;
                origin = DecodeOrigin.OpenWith;
                continue;
            }
            if (!token.StartsWith("--", StringComparison.Ordinal) && File.Exists(token))
                paths.Add(Path.GetFullPath(token));
        }
        return new(!background, origin, paths);
    }

    private static IReadOnlyList<string> CommandLineToArgs(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine)) return [];
        var arguments = new List<string>();
        var current = new System.Text.StringBuilder();
        var quoted = false;
        for (var index = 0; index < commandLine.Length; index++)
        {
            var character = commandLine[index];
            if (character == '"')
            {
                quoted = !quoted;
                continue;
            }
            if (char.IsWhiteSpace(character) && !quoted)
            {
                if (current.Length > 0)
                {
                    arguments.Add(current.ToString());
                    current.Clear();
                }
                continue;
            }
            if (character == '\\' && index + 1 < commandLine.Length && commandLine[index + 1] == '"')
            {
                current.Append('"');
                index++;
                continue;
            }
            current.Append(character);
        }
        if (current.Length > 0) arguments.Add(current.ToString());
        return arguments;
    }
}
