using System.Text.Json.Serialization;

namespace SirkUpdater.Core;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum UpdatePhase
{
    Queued,
    Verifying,
    BackingUp,
    Maintenance,
    Stopping,
    Installing,
    Starting,
    HealthChecking,
    Completed,
    RollingBack,
    Failed
}

public sealed record UpdateState
{
    public required string OperationId { get; init; }
    public required string ApplicationId { get; init; }
    public UpdatePhase Phase { get; init; }
    public int Progress { get; init; }
    public string? TargetVersion { get; init; }
    public string? Message { get; init; }
    public string? Error { get; init; }
    public DateTimeOffset StartedAtUtc { get; init; }
    public DateTimeOffset UpdatedAtUtc { get; init; }
    public DateTimeOffset? CompletedAtUtc { get; init; }
}
