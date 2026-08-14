using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace XDecode.Application;

public sealed record UpdateRelease(
    string Version,
    Uri DownloadUri,
    long SizeBytes,
    string? ReleaseNotes);

public sealed record UpdateAvailability(bool IsUpdateAvailable, UpdateRelease Release);

public sealed class UpdateChecker(
    HttpClient httpClient,
    Uri? endpoint = null,
    TimeSpan? retryDelay = null)
{
    public static readonly Uri ReleasesEndpoint = new(
        "https://flatstore.sfhw.cc/api/apps/5064015e-5fab-4aa6-9943-67678c272378/releases?platform=Windows&limit=1");

    private readonly Uri _endpoint = endpoint ?? ReleasesEndpoint;
    private readonly TimeSpan _retryDelay = retryDelay ?? TimeSpan.FromMilliseconds(500);

    public async Task<UpdateAvailability> CheckAsync(
        string currentVersion,
        CancellationToken cancellationToken = default)
    {
        using var response = await SendAsync(currentVersion, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound)
            throw new UpdateCheckException("暂未找到可用的 Windows 发布版本。");
        if (!response.IsSuccessStatusCode)
            throw new UpdateCheckException($"更新服务暂时不可用（HTTP {(int)response.StatusCode}）。");

        FlatStoreReleasesResponse? payload;
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            payload = await JsonSerializer.DeserializeAsync(
                stream, UpdateJsonContext.Default.FlatStoreReleasesResponse, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (JsonException)
        {
            throw new UpdateCheckException("更新服务返回了无法识别的数据。");
        }

        var currentRelease = payload?.CurrentRelease
            ?? throw new UpdateCheckException("暂未找到可用的 Windows 发布版本。");
        if (string.IsNullOrWhiteSpace(currentRelease.DownloadUrl) ||
            !Uri.TryCreate(_endpoint, currentRelease.DownloadUrl, out var downloadUri) ||
            downloadUri.Scheme != Uri.UriSchemeHttps ||
            string.IsNullOrWhiteSpace(currentRelease.Version) ||
            currentRelease.SizeBytes <= 0)
        {
            throw new UpdateCheckException("更新服务返回了无法识别的数据。");
        }

        var release = new UpdateRelease(
            currentRelease.Version,
            downloadUri,
            currentRelease.SizeBytes,
            currentRelease.ReleaseNotes);
        return new(ParseVersion(release.Version) > ParseVersion(currentVersion), release);
    }

    private async Task<HttpResponseMessage> SendAsync(
        string currentVersion,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, _endpoint);
            request.Headers.Accept.ParseAdd("application/json");
            request.Headers.UserAgent.ParseAdd($"XDecode/{currentVersion}");
            try
            {
                return await httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (HttpRequestException exception) when (
                attempt == 0 && IsRetryableTransportError(exception))
            {
                await Task.Delay(_retryDelay, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    private static bool IsRetryableTransportError(HttpRequestException exception) =>
        exception.HttpRequestError is
            HttpRequestError.ConnectionError or
            HttpRequestError.NameResolutionError or
            HttpRequestError.ResponseEnded;

    public static Version ParseVersion(string rawValue)
    {
        var value = rawValue.Trim();
        if (value.StartsWith('v') || value.StartsWith('V')) value = value[1..];
        value = value.Split(['-', '+'], 2)[0];
        var parts = value.Split('.');
        if (parts.Length == 0 || parts.Length > 4 || parts.Any(part => !int.TryParse(part, out _)))
            throw new UpdateCheckException($"无法识别版本号“{rawValue}”。");
        var normalized = parts.Select(int.Parse).Concat(Enumerable.Repeat(0, 4)).Take(4).ToArray();
        return new(normalized[0], normalized[1], normalized[2], normalized[3]);
    }
}

public sealed record UpdateDownloadProgress(long BytesReceived, long TotalBytes)
{
    public double Percentage => TotalBytes <= 0
        ? 0
        : Math.Clamp((double)BytesReceived / TotalBytes * 100, 0, 100);
}

public sealed class UpdatePackageDownloader(HttpClient httpClient, string? downloadsDirectory = null)
{
    public const long MaximumPackageSize = 1_073_741_824;

    private readonly string _downloadsDirectory = Path.GetFullPath(downloadsDirectory ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));

    public async Task<string> DownloadAsync(
        UpdateRelease release,
        IProgress<UpdateDownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (release.SizeBytes is <= 0 or > MaximumPackageSize)
            throw new UpdateDownloadException($"安装包声明的大小无效（{release.SizeBytes} 字节）。");
        if (release.DownloadUri.Scheme != Uri.UriSchemeHttps)
            throw new UpdateDownloadException("安装包下载地址无效。");
        if (!Directory.Exists(_downloadsDirectory))
            throw new UpdateDownloadException("无法访问下载文件夹。");

        var temporaryPath = Path.Combine(
            _downloadsDirectory, $".xdecode-update-{Guid.NewGuid():N}.tmp");
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, release.DownloadUri);
            request.Headers.Accept.ParseAdd("application/octet-stream");
            request.Headers.UserAgent.ParseAdd($"XDecode/{release.Version}");
            using var response = await httpClient.SendAsync(
                request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new UpdateDownloadException(
                    $"安装包下载失败（HTTP {(int)response.StatusCode}）。");

            var contentLength = response.Content.Headers.ContentLength;
            if (contentLength is > MaximumPackageSize)
                throw new UpdateDownloadException("安装包超过允许的 1 GiB 上限。");
            if (contentLength is not null && contentLength != release.SizeBytes)
                throw SizeMismatch(release.SizeBytes, contentLength.Value);

            await DownloadToFileAsync(
                response.Content, temporaryPath, release.SizeBytes, progress, cancellationToken)
                .ConfigureAwait(false);
            ValidateWindowsExecutable(temporaryPath, release.SizeBytes);

            var suggestedFilename = SuggestedFilename(response.Content.Headers.ContentDisposition);
            return PublishPackage(temporaryPath, suggestedFilename, release.Version);
        }
        finally
        {
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    public static void ValidateWindowsExecutable(string path, long expectedSize)
    {
        FileInfo file;
        try { file = new FileInfo(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new UpdateDownloadException("下载的文件不是有效的 Windows x64 安装程序。");
        }

        if (!file.Exists || file.Length != expectedSize)
            throw SizeMismatch(expectedSize, file.Exists ? file.Length : 0);
        if (file.Length < 64)
            throw new UpdateDownloadException("下载的文件不是有效的 Windows x64 安装程序。");

        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var reader = new BinaryReader(stream);
            if (reader.ReadUInt16() != 0x5A4D)
                throw InvalidExecutable();
            stream.Position = 0x3C;
            var peOffset = reader.ReadInt32();
            if (peOffset < 0 || peOffset > stream.Length - 6)
                throw InvalidExecutable();
            stream.Position = peOffset;
            if (reader.ReadUInt32() != 0x00004550 || reader.ReadUInt16() != 0x8664)
                throw InvalidExecutable();
        }
        catch (UpdateDownloadException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or EndOfStreamException)
        {
            throw InvalidExecutable();
        }
    }

    private static async Task DownloadToFileAsync(
        HttpContent content,
        string path,
        long expectedSize,
        IProgress<UpdateDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        await using var input = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var output = new FileStream(
            path, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            64 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough);
        var buffer = new byte[64 * 1024];
        long received = 0;
        while (true)
        {
            var count = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            received += count;
            if (received > expectedSize || received > MaximumPackageSize)
                throw SizeMismatch(expectedSize, received);
            await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
            progress?.Report(new(received, expectedSize));
        }
        await output.FlushAsync(cancellationToken).ConfigureAwait(false);
        output.Flush(flushToDisk: true);
        if (received != expectedSize) throw SizeMismatch(expectedSize, received);
    }

    private string PublishPackage(string temporaryPath, string? suggestedFilename, string version)
    {
        var filename = PackageFilename(suggestedFilename, version);
        var name = Path.GetFileNameWithoutExtension(filename);
        for (var index = 0; index <= 999; index++)
        {
            var suffix = index == 0 ? "" : $"-{index}";
            var destination = Path.Combine(_downloadsDirectory, $"{name}{suffix}.exe");
            try
            {
                File.Move(temporaryPath, destination, overwrite: false);
                return destination;
            }
            catch (IOException) when (File.Exists(destination))
            {
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                throw new UpdateDownloadException("无法将安装包保存到下载文件夹。");
            }
        }
        throw new UpdateDownloadException("无法将安装包保存到下载文件夹。");
    }

    private static string PackageFilename(string? suggestedFilename, string version)
    {
        if (!string.IsNullOrWhiteSpace(suggestedFilename))
        {
            var filename = Path.GetFileName(suggestedFilename.Trim('"'));
            if (Path.GetExtension(filename).Equals(".exe", StringComparison.OrdinalIgnoreCase))
                return filename;
        }

        var safeVersion = new string(version.Select(character =>
            char.IsAsciiDigit(character) || character is '.' or '-' ? character : '-').ToArray());
        return $"XDecode-{safeVersion}.exe";
    }

    private static string? SuggestedFilename(ContentDispositionHeaderValue? disposition) =>
        disposition?.FileNameStar ?? disposition?.FileName;

    private static UpdateDownloadException SizeMismatch(long expected, long actual) =>
        new($"安装包大小校验失败（应为 {expected} 字节，实际为 {actual} 字节）。");

    private static UpdateDownloadException InvalidExecutable() =>
        new("下载的文件不是有效的 Windows x64 安装程序。");
}

public sealed class UpdateCheckException(string message) : Exception(message);
public sealed class UpdateDownloadException(string message) : Exception(message);

public sealed record FlatStoreReleasesResponse(
    [property: JsonPropertyName("currentRelease")] FlatStoreReleaseResponse? CurrentRelease);

public sealed record FlatStoreReleaseResponse(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("downloadUrl")] string DownloadUrl,
    [property: JsonPropertyName("sizeBytes")] long SizeBytes,
    [property: JsonPropertyName("releaseNotes")] string? ReleaseNotes);

[JsonSerializable(typeof(FlatStoreReleasesResponse))]
internal sealed partial class UpdateJsonContext : JsonSerializerContext;
