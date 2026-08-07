using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;

namespace SirkUpdater.Core;

public sealed class TransactionalUpdateEngine
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly ApplicationRegistry _registry;
    private readonly string _root;
    private readonly HttpClient _http;

    public TransactionalUpdateEngine(ApplicationRegistry? registry = null, string? root = null, HttpMessageHandler? handler = null)
    {
        _registry = registry ?? new ApplicationRegistry();
        _root = Path.GetFullPath(root ?? ApplicationRegistry.PlatformDataRoot());
        handler ??= new HttpClientHandler();
        _http = new HttpClient(handler, disposeHandler: true);
    }

    public async Task<UpdateState> ExecuteAsync(UpdateRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var manifest = _registry.Get(request.ApplicationId);
        var operationId = DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + Guid.NewGuid().ToString("N")[..8];
        var operationRoot = Path.Combine(_root, "operations", manifest.ApplicationId, operationId);
        var stagingRoot = Path.Combine(operationRoot, "staging");
        var backupRoot = Path.Combine(operationRoot, "backup");
        var statePath = Path.Combine(operationRoot, "state.json");
        var maintenancePath = Path.Combine(manifest.DataRoot, "maintenance.lock");
        var started = DateTimeOffset.UtcNow;
        var backupReady = false;
        var applicationStopped = false;
        var watchdogStopped = false;
        var installationTouched = false;

        Directory.CreateDirectory(operationRoot);
        var state = NewState(UpdatePhase.Queued, 0, "Operation queued.");
        Persist(statePath, state);

        try
        {
            state = Set(UpdatePhase.Verifying, 5, "Verifying update package checksum and archive safety.");
            await VerifyPackageAsync(request, cancellationToken);

            Directory.CreateDirectory(stagingRoot);
            ZipFile.ExtractToDirectory(request.PackagePath, stagingRoot, overwriteFiles: true);
            var payloadRoot = ResolvePayloadRoot(stagingRoot);

            if (manifest.SignatureRequired)
            {
                state = Set(UpdatePhase.Verifying, 10, "Verifying signed application payload.");
                VerifySignedPayload(manifest, payloadRoot);
            }

            state = Set(UpdatePhase.BackingUp, 15, "Creating application backup.");
            CopyDirectory(manifest.InstallRoot, backupRoot);
            backupReady = true;

            state = Set(UpdatePhase.Maintenance, 25, "Entering maintenance mode.");
            Directory.CreateDirectory(manifest.DataRoot);
            AtomicWrite(maintenancePath, JsonSerializer.Serialize(new
            {
                operationId,
                applicationId = manifest.ApplicationId,
                targetVersion = request.TargetVersion,
                startedAtUtc = DateTimeOffset.UtcNow
            }, JsonOptions));

            if (!string.IsNullOrWhiteSpace(manifest.WatchdogServiceName))
            {
                StopService(manifest.WatchdogServiceName!, allowNotRunning: true);
                watchdogStopped = true;
            }

            state = Set(UpdatePhase.Stopping, 35, "Stopping application service.");
            StopService(manifest.ServiceName, allowNotRunning: true);
            applicationStopped = true;

            state = Set(UpdatePhase.Installing, 50, "Installing verified package.");
            installationTouched = true;
            MirrorDirectory(payloadRoot, manifest.InstallRoot);

            state = Set(UpdatePhase.Starting, 75, "Starting application service.");
            ConfigureAutomatic(manifest.ServiceName);
            StartService(manifest.ServiceName);
            applicationStopped = false;

            state = Set(UpdatePhase.HealthChecking, 85, "Waiting for application health.");
            await WaitForHealthAsync(manifest, request.HealthTimeout, cancellationToken);

            if (!string.IsNullOrWhiteSpace(manifest.WatchdogServiceName))
            {
                ConfigureAutomatic(manifest.WatchdogServiceName!);
                StartService(manifest.WatchdogServiceName!, allowAlreadyRunning: true);
                watchdogStopped = false;
            }

            TryDelete(maintenancePath);
            state = Set(UpdatePhase.Completed, 100, "Update completed.", completed: true);
            return state;
        }
        catch (Exception updateError)
        {
            try
            {
                if (installationTouched)
                {
                    state = Set(UpdatePhase.RollingBack, 90, "Update failed. Restoring backup.", updateError.Message);
                    StopService(manifest.ServiceName, allowNotRunning: true);
                    applicationStopped = true;
                    if (!backupReady || !Directory.Exists(backupRoot))
                        throw new DirectoryNotFoundException("Rollback backup is unavailable.");
                    MirrorDirectory(backupRoot, manifest.InstallRoot);
                }

                if (applicationStopped)
                {
                    ConfigureAutomatic(manifest.ServiceName);
                    StartService(manifest.ServiceName, allowAlreadyRunning: true);
                    applicationStopped = false;
                    await WaitForHealthAsync(manifest, request.HealthTimeout, cancellationToken);
                }

                if (watchdogStopped && !string.IsNullOrWhiteSpace(manifest.WatchdogServiceName))
                {
                    ConfigureAutomatic(manifest.WatchdogServiceName!);
                    StartService(manifest.WatchdogServiceName!, allowAlreadyRunning: true);
                    watchdogStopped = false;
                }
            }
            catch (Exception rollbackError)
            {
                updateError = new AggregateException("Update and recovery failed.", updateError, rollbackError);
            }
            finally
            {
                TryDelete(maintenancePath);
                TryConfigureAutomatic(manifest.ServiceName);
                if (!string.IsNullOrWhiteSpace(manifest.WatchdogServiceName))
                    TryConfigureAutomatic(manifest.WatchdogServiceName!);
            }

            var message = installationTouched
                ? "Update failed; rollback was attempted."
                : "Update was rejected before the installed application was modified.";
            state = Set(UpdatePhase.Failed, 100, message, updateError.ToString(), completed: true);
            throw new UpdateFailedException(state, updateError);
        }

        UpdateState NewState(UpdatePhase phase, int progress, string message, string? error = null, bool completed = false) => new()
        {
            OperationId = operationId,
            ApplicationId = manifest.ApplicationId,
            Phase = phase,
            Progress = progress,
            TargetVersion = request.TargetVersion,
            Message = message,
            Error = error,
            StartedAtUtc = started,
            UpdatedAtUtc = DateTimeOffset.UtcNow,
            CompletedAtUtc = completed ? DateTimeOffset.UtcNow : null
        };

        UpdateState Set(UpdatePhase phase, int progress, string message, string? error = null, bool completed = false)
        {
            var next = NewState(phase, progress, message, error, completed);
            Persist(statePath, next);
            return next;
        }
    }

    private static async Task VerifyPackageAsync(UpdateRequest request, CancellationToken cancellationToken)
    {
        if (!File.Exists(request.PackagePath)) throw new FileNotFoundException("Update package was not found.", request.PackagePath);
        if (!request.PackagePath.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Update package must be a ZIP archive.");
        if (!System.Text.RegularExpressions.Regex.IsMatch(request.ExpectedSha256, "^[a-fA-F0-9]{64}$"))
            throw new InvalidDataException("Expected SHA256 must contain 64 hexadecimal characters.");

        await using var stream = new FileStream(request.PackagePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 128, useAsync: true);
        var digest = await SHA256.HashDataAsync(stream, cancellationToken);
        var actual = Convert.ToHexString(digest);
        if (!actual.Equals(request.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
            throw new CryptographicException($"Package SHA256 mismatch. Actual: {actual}.");

        using var archive = ZipFile.OpenRead(request.PackagePath);
        foreach (var entry in archive.Entries)
        {
            var normalized = entry.FullName.Replace('\\', '/');
            if (normalized.StartsWith('/') || normalized.Split('/').Any(segment => segment == ".."))
                throw new InvalidDataException($"Unsafe ZIP entry: {entry.FullName}");
        }
    }

    private static void VerifySignedPayload(ApplicationManifest manifest, string payloadRoot)
    {
        var verifier = Path.GetFullPath(manifest.SignatureVerifierPath!);
        if (!File.Exists(verifier))
            throw new FileNotFoundException("Configured signature verifier was not found.", verifier);
        var arguments = manifest.SignatureVerifierArguments
            .Select(value => value.Replace("{payload}", payloadRoot, StringComparison.Ordinal))
            .ToArray();
        var result = Run(verifier, arguments);
        if (result.ExitCode != 0)
            throw new CryptographicException($"Application signature verification failed: {result.Output}");
    }

    private async Task WaitForHealthAsync(ApplicationManifest manifest, TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(manifest.HealthUrl))
        {
            await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
            return;
        }
        var healthUri = ValidateHealthUri(manifest.HealthUrl);
        var deadline = DateTimeOffset.UtcNow + timeout;
        Exception? last = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var response = await _http.GetAsync(healthUri, cancellationToken);
                if (response.StatusCode is >= HttpStatusCode.OK and < HttpStatusCode.BadRequest) return;
                last = new HttpRequestException($"Health endpoint returned HTTP {(int)response.StatusCode}.");
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                last = error;
            }
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
        }
        throw new TimeoutException("Application health check timed out.", last);
    }

    internal static Uri ValidateHealthUri(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
            throw new InvalidDataException("Application health URL must be an absolute URI.");
        if (uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return uri;
        if (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && IsLoopbackHost(uri.Host)) return uri;
        throw new InvalidDataException("Application health URL must use HTTPS unless it targets localhost or a loopback address.");
    }

    private static bool IsLoopbackHost(string host)
    {
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase)) return true;
        return IPAddress.TryParse(host, out var address) && IPAddress.IsLoopback(address);
    }

    private static string ResolvePayloadRoot(string stagingRoot)
    {
        var entries = Directory.EnumerateFileSystemEntries(stagingRoot).ToArray();
        if (entries.Length == 1 && Directory.Exists(entries[0])) return entries[0];
        return stagingRoot;
    }

    private static void StopService(string name, bool allowNotRunning)
    {
        if (OperatingSystem.IsWindows())
        {
            var result = Run("sc.exe", ["stop", name]);
            var output = result.Output;
            if (result.ExitCode != 0 && !(allowNotRunning && (output.Contains("1062") || output.Contains("SERVICE_NOT_ACTIVE", StringComparison.OrdinalIgnoreCase))))
                throw new InvalidOperationException($"Unable to stop service {name}: {output}");
            if (result.ExitCode == 0) WaitService(name, "stopped", TimeSpan.FromMinutes(2));
            return;
        }

        EnsureSystemd();
        var linux = Run("systemctl", ["stop", name]);
        if (linux.ExitCode != 0)
        {
            var state = Run("systemctl", ["is-active", name]);
            if (!(allowNotRunning && state.ExitCode == 3))
                throw new InvalidOperationException($"Unable to stop service {name}: {linux.Output}");
        }
        WaitService(name, "stopped", TimeSpan.FromMinutes(2));
    }

    private static void StartService(string name, bool allowAlreadyRunning = false)
    {
        if (OperatingSystem.IsWindows())
        {
            var result = Run("sc.exe", ["start", name]);
            var output = result.Output;
            if (result.ExitCode != 0 && !(allowAlreadyRunning && (output.Contains("1056") || output.Contains("ALREADY_RUNNING", StringComparison.OrdinalIgnoreCase))))
                throw new InvalidOperationException($"Unable to start service {name}: {output}");
            WaitService(name, "running", TimeSpan.FromMinutes(2));
            return;
        }

        EnsureSystemd();
        if (allowAlreadyRunning && Run("systemctl", ["is-active", "--quiet", name]).ExitCode == 0) return;
        var linux = Run("systemctl", ["start", name]);
        if (linux.ExitCode != 0)
            throw new InvalidOperationException($"Unable to start service {name}: {linux.Output}");
        WaitService(name, "running", TimeSpan.FromMinutes(2));
    }

    private static void ConfigureAutomatic(string name)
    {
        if (OperatingSystem.IsWindows())
        {
            var result = Run("sc.exe", ["config", name, "start=", "auto"]);
            if (result.ExitCode != 0) throw new InvalidOperationException($"Unable to configure service {name}: {result.Output}");
            return;
        }

        EnsureSystemd();
        var linux = Run("systemctl", ["enable", name]);
        if (linux.ExitCode != 0) throw new InvalidOperationException($"Unable to enable service {name}: {linux.Output}");
    }

    private static void TryConfigureAutomatic(string name)
    {
        try { ConfigureAutomatic(name); } catch { }
    }

    private static void WaitService(string name, string desired, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (OperatingSystem.IsWindows())
            {
                var expected = desired == "running" ? "STATE              : 4" : "STATE              : 1";
                var label = desired == "running" ? "RUNNING" : "STOPPED";
                var result = Run("sc.exe", ["query", name]);
                if (result.Output.Contains(expected, StringComparison.OrdinalIgnoreCase) &&
                    result.Output.Contains(label, StringComparison.OrdinalIgnoreCase)) return;
            }
            else
            {
                EnsureSystemd();
                var result = Run("systemctl", ["is-active", "--quiet", name]);
                if (desired == "running" && result.ExitCode == 0) return;
                if (desired == "stopped" && result.ExitCode == 3) return;
            }
            Thread.Sleep(500);
        }
        throw new TimeoutException($"Service {name} did not reach {desired}.");
    }

    private static (int ExitCode, string Output) Run(string file, IReadOnlyList<string> arguments)
    {
        var start = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"Unable to start {file}.");
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return (process.ExitCode, (stdout + Environment.NewLine + stderr).Trim());
    }

    private static void CopyDirectory(string source, string destination)
    {
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException($"Application root does not exist: {source}");
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, directory)));
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: true);
        }
    }

    private static void MirrorDirectory(string source, string destination)
    {
        var preserve = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Service" };
        Directory.CreateDirectory(destination);
        foreach (var entry in Directory.EnumerateFileSystemEntries(destination))
        {
            if (preserve.Contains(Path.GetFileName(entry))) continue;
            if (Directory.Exists(entry)) Directory.Delete(entry, recursive: true); else File.Delete(entry);
        }
        foreach (var entry in Directory.EnumerateFileSystemEntries(source))
        {
            if (preserve.Contains(Path.GetFileName(entry))) continue;
            var target = Path.Combine(destination, Path.GetFileName(entry));
            if (Directory.Exists(entry)) CopyDirectory(entry, target); else File.Copy(entry, target, overwrite: true);
        }
    }

    private static void Persist(string statePath, UpdateState state) => AtomicWrite(statePath, JsonSerializer.Serialize(state, JsonOptions));

    private static void AtomicWrite(string path, string content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temporary, content);
        File.Move(temporary, path, overwrite: true);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    private static void EnsureSystemd()
    {
        if (OperatingSystem.IsWindows()) return;
        if (!OperatingSystem.IsLinux())
            throw new PlatformNotSupportedException("Service transactions require Windows or Linux systemd.");
        if (!File.Exists("/bin/systemctl") && !File.Exists("/usr/bin/systemctl"))
            throw new PlatformNotSupportedException("Linux service transactions require systemd/systemctl.");
    }
}

public sealed class UpdateFailedException : Exception
{
    public UpdateFailedException(UpdateState state, Exception innerException)
        : base(state.Error ?? "Update failed.", innerException) => State = state;

    public UpdateState State { get; }
}
