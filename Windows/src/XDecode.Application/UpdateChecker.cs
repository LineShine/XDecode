using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace XDecode.Application;

public sealed record UpdateRelease(string Version, Uri PageUri);
public sealed record UpdateAvailability(bool IsUpdateAvailable, UpdateRelease Release);

public sealed class UpdateChecker(HttpClient httpClient, Uri? endpoint = null)
{
    public static readonly Uri LatestReleaseEndpoint =
        new("https://api.github.com/repos/LineShine/XDecode/releases/latest");
    private readonly Uri _endpoint = endpoint ?? LatestReleaseEndpoint;

    public async Task<UpdateAvailability> CheckAsync(
        string currentVersion,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, _endpoint);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd($"XDecode/{currentVersion}");
        using var response = await httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound)
            throw new UpdateCheckException("暂未找到可用的发布版本。");
        if (!response.IsSuccessStatusCode)
            throw new UpdateCheckException($"更新服务暂时不可用（HTTP {(int)response.StatusCode}）。");
        var payload = await response.Content.ReadFromJsonAsync<GitHubRelease>(
            cancellationToken: cancellationToken).ConfigureAwait(false)
            ?? throw new UpdateCheckException("更新服务返回了无法识别的数据。");
        var release = new UpdateRelease(payload.TagName, payload.HtmlUrl);
        return new(ParseVersion(payload.TagName) > ParseVersion(currentVersion), release);
    }

    public static Version ParseVersion(string rawValue)
    {
        var value = rawValue.Trim();
        if (value.StartsWith('v') || value.StartsWith('V')) value = value[1..];
        value = value.Split(['-', '+'], 2)[0];
        var parts = value.Split('.');
        if (parts.Length == 0 || parts.Any(value => !int.TryParse(value, out _)))
            throw new UpdateCheckException($"无法识别版本号“{rawValue}”。");
        var normalized = parts.Select(int.Parse).Concat(Enumerable.Repeat(0, 4)).Take(4).ToArray();
        return new(normalized[0], normalized[1], normalized[2], normalized[3]);
    }

    private sealed record GitHubRelease(
        [property: JsonPropertyName("tag_name")] string TagName,
        [property: JsonPropertyName("html_url")] Uri HtmlUrl);
}

public sealed class UpdateCheckException(string message) : Exception(message);
