using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using XDecode.Core;

namespace XDecode.Application;

public sealed record XlogProfile(
    Guid Id, string Name, string FilePattern = FilenamePatternDefaults.Xlog);
public sealed record LoganProfile(
    Guid Id, string Name, string FilePattern = FilenamePatternDefaults.Logan);
public sealed record ZipPatternRule(Guid Id, string Pattern = FilenamePatternDefaults.Zip);

public sealed class SettingsDocument
{
    public int Version { get; set; } = 1;
    public bool AutomaticEnabled { get; set; } = true;
    public bool DownloadsMonitoringEnabled { get; set; } = true;
    public bool LaunchAtLoginEnabled { get; set; } = true;
    public bool NotificationsEnabled { get; set; } = true;
    public string MxFilePattern { get; set; } = FilenamePatternDefaults.Mx;
    public List<string> MonitoredFolders { get; set; } = [];
    public List<XlogProfile> XlogProfiles { get; set; } = [];
    public List<LoganProfile> LoganProfiles { get; set; } = [];
    public List<ZipPatternRule> ZipPatternRules { get; set; } =
        [new(Guid.NewGuid(), FilenamePatternDefaults.Zip)];
}

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() }
    };
    private readonly string _settingsPath;
    private readonly string _secretsPath;
    private readonly string _downloadsPath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private SecretDocument _secrets;

    public SettingsDocument Current { get; private set; }

    public SettingsStore(string localStateDirectory, string? downloadsPath = null)
    {
        Directory.CreateDirectory(localStateDirectory);
        _settingsPath = Path.Combine(localStateDirectory, "settings.v1.json");
        _secretsPath = Path.Combine(localStateDirectory, "secrets.v1.json");
        _downloadsPath = Path.GetFullPath(downloadsPath ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));
        Current = LoadSettings();
        _secrets = LoadSecrets();
        Normalize();
    }

    public IReadOnlyList<string> MonitoredFolders
    {
        get
        {
            var values = Current.MonitoredFolders
                .Select(NormalizePathOrNull)
                .OfType<string>().ToList();
            if (Current.DownloadsMonitoringEnabled) values.Insert(0, _downloadsPath);
            return values.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        }
    }

    public LogFormat? LogFormatFor(string path, bool includeZip = true)
    {
        if (includeZip && Path.GetExtension(path).Equals(".zip", StringComparison.OrdinalIgnoreCase) &&
            Current.ZipPatternRules.Any(rule => FilenamePattern.Matches(rule.Pattern, path)))
            return LogFormat.Zip;
        if (FilenamePattern.Matches(FilenamePatternDefaults.Xlog, path) ||
            Current.XlogProfiles.Any(profile => FilenamePattern.Matches(profile.FilePattern, path)))
            return LogFormat.Xlog;
        if (FilenamePattern.Matches(Current.MxFilePattern, path)) return LogFormat.Mx;
        if (Path.GetExtension(path).Equals(".logan", StringComparison.OrdinalIgnoreCase) ||
            Current.LoganProfiles.Any(profile => FilenamePattern.Matches(profile.FilePattern, path)) ||
            (Current.LoganProfiles.Count == 0 && FilenamePattern.Matches(FilenamePatternDefaults.Logan, path)))
            return LogFormat.Logan;
        return null;
    }

    public IReadOnlyList<XlogCredentials> XlogCredentialsFor(string path)
    {
        var values = new List<XlogCredentials>();
        foreach (var profile in Current.XlogProfiles.Where(value => FilenamePattern.Matches(value.FilePattern, path)))
        {
            if (!_secrets.XlogPrivateKeys.TryGetValue(profile.Id, out var protectedValue)) continue;
            try { values.Add(new XlogCredentials(Unprotect(protectedValue))); }
            catch (CryptographicException) { }
            catch (DecodeException) { }
        }
        return values;
    }

    public IReadOnlyList<LoganCredentials> LoganCredentialsFor(string path)
    {
        var values = new List<LoganCredentials>();
        foreach (var profile in Current.LoganProfiles.Where(value => FilenamePattern.Matches(value.FilePattern, path)))
        {
            if (!_secrets.LoganCredentials.TryGetValue(profile.Id, out var value)) continue;
            try { values.Add(new LoganCredentials(Unprotect(value.Key), Unprotect(value.IV))); }
            catch (CryptographicException) { }
            catch (DecodeException) { }
        }
        return values;
    }

    public async Task SaveAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Normalize();
            await AtomicJson.WriteAsync(_settingsPath, Current, JsonOptions, cancellationToken).ConfigureAwait(false);
            await AtomicJson.WriteAsync(_secretsPath, _secrets, JsonOptions, cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task SaveXlogPrivateKeyAsync(
        Guid profileId, byte[] privateKey, CancellationToken cancellationToken = default)
    {
        _ = new XlogCredentials(privateKey);
        _secrets.XlogPrivateKeys[profileId] = Protect(privateKey);
        await SaveAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task SaveLoganCredentialsAsync(
        Guid profileId, byte[] key, byte[] iv, CancellationToken cancellationToken = default)
    {
        _ = new LoganCredentials(key, iv);
        _secrets.LoganCredentials[profileId] = new ProtectedLoganSecret(Protect(key), Protect(iv));
        await SaveAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task RemoveXlogProfileAsync(Guid id, CancellationToken cancellationToken = default)
    {
        Current.XlogProfiles.RemoveAll(value => value.Id == id);
        _secrets.XlogPrivateKeys.Remove(id);
        await SaveAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task RemoveLoganProfileAsync(Guid id, CancellationToken cancellationToken = default)
    {
        Current.LoganProfiles.RemoveAll(value => value.Id == id);
        _secrets.LoganCredentials.Remove(id);
        await SaveAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task AddMonitoredFolderAsync(string path, CancellationToken cancellationToken = default)
    {
        var normalized = Path.GetFullPath(path);
        if (normalized.Equals(_downloadsPath, StringComparison.OrdinalIgnoreCase))
            Current.DownloadsMonitoringEnabled = true;
        else if (!Current.MonitoredFolders.Contains(normalized, StringComparer.OrdinalIgnoreCase))
            Current.MonitoredFolders.Add(normalized);
        await SaveAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task RemoveMonitoredFolderAsync(string path, CancellationToken cancellationToken = default)
    {
        var normalized = Path.GetFullPath(path);
        Current.MonitoredFolders.RemoveAll(value => value.Equals(normalized, StringComparison.OrdinalIgnoreCase));
        if (normalized.Equals(_downloadsPath, StringComparison.OrdinalIgnoreCase))
            Current.DownloadsMonitoringEnabled = false;
        await SaveAsync(cancellationToken).ConfigureAwait(false);
    }

    private SettingsDocument LoadSettings()
    {
        try
        {
            return File.Exists(_settingsPath)
                ? JsonSerializer.Deserialize<SettingsDocument>(File.ReadAllBytes(_settingsPath), JsonOptions) ?? new()
                : new();
        }
        catch (JsonException) { return new(); }
        catch (IOException) { return new(); }
    }

    private SecretDocument LoadSecrets()
    {
        try
        {
            return File.Exists(_secretsPath)
                ? JsonSerializer.Deserialize<SecretDocument>(File.ReadAllBytes(_secretsPath), JsonOptions) ?? new()
                : new();
        }
        catch (JsonException) { return new(); }
        catch (IOException) { return new(); }
    }

    private void Normalize()
    {
        Current.Version = 1;
        Current.MonitoredFolders = Current.MonitoredFolders
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(NormalizePathOrNull)
            .OfType<string>()
            .Where(value => !value.Equals(_downloadsPath, StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        Current.LoganProfiles = Current.LoganProfiles.Select(value =>
            value.FilePattern == "*.logan" ? value with { FilePattern = FilenamePatternDefaults.Logan } : value).ToList();
        if (Current.ZipPatternRules.Count == 0)
            Current.ZipPatternRules.Add(new(Guid.NewGuid(), FilenamePatternDefaults.Zip));
    }

    private static byte[] Protect(byte[] value) =>
        ProtectedData.Protect(value, optionalEntropy: null, DataProtectionScope.CurrentUser);
    private static byte[] Unprotect(byte[] value) =>
        ProtectedData.Unprotect(value, optionalEntropy: null, DataProtectionScope.CurrentUser);

    private static string? NormalizePathOrNull(string path)
    {
        try { return Path.GetFullPath(path); }
        catch (ArgumentException) { return null; }
        catch (NotSupportedException) { return null; }
        catch (PathTooLongException) { return null; }
    }

    public sealed class SecretDocument
    {
        public int Version { get; set; } = 1;
        public Dictionary<Guid, byte[]> XlogPrivateKeys { get; set; } = [];
        public Dictionary<Guid, ProtectedLoganSecret> LoganCredentials { get; set; } = [];
    }

    public sealed record ProtectedLoganSecret(byte[] Key, byte[] IV);
}

internal static class AtomicJson
{
    public static async Task WriteAsync<T>(
        string path, T value, JsonSerializerOptions options, CancellationToken cancellationToken)
    {
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            await using (var stream = new FileStream(
                temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                64 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, value, options, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
            catch { }
        }
    }
}
