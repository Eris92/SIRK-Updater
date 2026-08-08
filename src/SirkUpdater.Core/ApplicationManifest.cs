using System.Text.Json.Serialization;

namespace SirkUpdater.Core;

public sealed record ApplicationManifest
{
    public const string CentralCacheSource = "sirk-central-cache";

    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; } = 1;

    [JsonPropertyName("applicationId")]
    public required string ApplicationId { get; init; }

    [JsonPropertyName("displayName")]
    public required string DisplayName { get; init; }

    [JsonPropertyName("serviceName")]
    public required string ServiceName { get; init; }

    [JsonPropertyName("watchdogServiceName")]
    public string? WatchdogServiceName { get; init; }

    [JsonPropertyName("installRoot")]
    public required string InstallRoot { get; init; }

    [JsonPropertyName("dataRoot")]
    public required string DataRoot { get; init; }

    [JsonPropertyName("healthUrl")]
    public string? HealthUrl { get; init; }

    [JsonPropertyName("channel")]
    public string Channel { get; init; } = "stable";

    [JsonPropertyName("updateSource")]
    public required string UpdateSource { get; init; }

    [JsonPropertyName("packageSha256Url")]
    public string? PackageSha256Url { get; init; }

    [JsonPropertyName("signatureRequired")]
    public bool SignatureRequired { get; init; } = true;

    [JsonPropertyName("signatureVerifierPath")]
    public string? SignatureVerifierPath { get; init; }

    [JsonPropertyName("signatureVerifierArguments")]
    public IReadOnlyList<string> SignatureVerifierArguments { get; init; } = [];

    [JsonPropertyName("preserveFiles")]
    public IReadOnlyList<string> PreserveFiles { get; init; } = [];

    public void Validate()
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(ApplicationId, "^[a-z0-9][a-z0-9._-]{1,63}$"))
            throw new InvalidDataException("Invalid applicationId.");
        if (string.IsNullOrWhiteSpace(DisplayName)) throw new InvalidDataException("displayName is required.");
        if (string.IsNullOrWhiteSpace(ServiceName)) throw new InvalidDataException("serviceName is required.");
        if (!Path.IsPathFullyQualified(InstallRoot)) throw new InvalidDataException("installRoot must be absolute.");
        if (!Path.IsPathFullyQualified(DataRoot)) throw new InvalidDataException("dataRoot must be absolute.");
        if (!string.Equals(UpdateSource, CentralCacheSource, StringComparison.Ordinal) &&
            (!Uri.TryCreate(UpdateSource, UriKind.Absolute, out var source) || source.Scheme != Uri.UriSchemeHttps))
            throw new InvalidDataException("updateSource must be sirk-central-cache or an absolute HTTPS URL.");
        if (HealthUrl is not null && (!Uri.TryCreate(HealthUrl, UriKind.Absolute, out var health) || health.Scheme is not ("http" or "https")))
            throw new InvalidDataException("healthUrl must be HTTP or HTTPS.");

        if (PreserveFiles.Count > 64)
            throw new InvalidDataException("preserveFiles contains too many entries.");
        var preserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in PreserveFiles)
        {
            var normalized = (value ?? string.Empty).Replace('\\', '/');
            if (normalized.Length is <= 0 or > 255 ||
                normalized.StartsWith('/') ||
                normalized.EndsWith('/') ||
                normalized.Contains('/', StringComparison.Ordinal) ||
                normalized.Contains(':', StringComparison.Ordinal) ||
                Path.IsPathRooted(normalized) ||
                normalized is "." or ".." ||
                !preserved.Add(normalized))
                throw new InvalidDataException("preserveFiles contains an invalid top-level relative file path.");
        }

        if (!SignatureRequired) return;
        if (string.IsNullOrWhiteSpace(SignatureVerifierPath) || !Path.IsPathFullyQualified(SignatureVerifierPath))
            throw new InvalidDataException("signatureVerifierPath must be an absolute path when signatureRequired is true.");

        var installRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(InstallRoot));
        var verifier = Path.GetFullPath(SignatureVerifierPath);
        var relative = Path.GetRelativePath(installRoot, verifier);
        if (relative.Equals("..", StringComparison.Ordinal) ||
            relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) ||
            Path.IsPathFullyQualified(relative))
            throw new InvalidDataException("signatureVerifierPath must be located below installRoot.");
        if (SignatureVerifierArguments.Count == 0 ||
            !SignatureVerifierArguments.Any(value => value.Contains("{payload}", StringComparison.Ordinal)))
            throw new InvalidDataException("signatureVerifierArguments must include the {payload} placeholder.");
        if (SignatureVerifierArguments.Any(value => value.Contains('\0') || value.Length > 4096))
            throw new InvalidDataException("signatureVerifierArguments contains an invalid argument.");
    }
}
