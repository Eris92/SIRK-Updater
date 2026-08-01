using System.Text.Json.Serialization;

namespace SirkUpdater.Core;

public sealed record ApplicationManifest
{
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

    public void Validate()
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(ApplicationId, "^[a-z0-9][a-z0-9._-]{1,63}$"))
            throw new InvalidDataException("Invalid applicationId.");
        if (string.IsNullOrWhiteSpace(DisplayName)) throw new InvalidDataException("displayName is required.");
        if (string.IsNullOrWhiteSpace(ServiceName)) throw new InvalidDataException("serviceName is required.");
        if (!Path.IsPathFullyQualified(InstallRoot)) throw new InvalidDataException("installRoot must be absolute.");
        if (!Path.IsPathFullyQualified(DataRoot)) throw new InvalidDataException("dataRoot must be absolute.");
        if (!Uri.TryCreate(UpdateSource, UriKind.Absolute, out var source) || source.Scheme != Uri.UriSchemeHttps)
            throw new InvalidDataException("updateSource must be an absolute HTTPS URL.");
        if (HealthUrl is not null && (!Uri.TryCreate(HealthUrl, UriKind.Absolute, out var health) || health.Scheme is not ("http" or "https")))
            throw new InvalidDataException("healthUrl must be HTTP or HTTPS.");
    }
}
