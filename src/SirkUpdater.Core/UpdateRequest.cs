namespace SirkUpdater.Core;

public sealed record UpdateRequest
{
    public required string ApplicationId { get; init; }
    public required string PackagePath { get; init; }
    public required string ExpectedSha256 { get; init; }
    public string? TargetVersion { get; init; }
    public TimeSpan HealthTimeout { get; init; } = TimeSpan.FromMinutes(2);
}
