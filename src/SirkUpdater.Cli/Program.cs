using System.Text.Json;
using SirkUpdater.Core;

return await RunAsync(args);

static async Task<int> RunAsync(string[] args)
{
    try
    {
        var registry = new ApplicationRegistry();
        if (args.Length == 2 && args[0].Equals("register", StringComparison.OrdinalIgnoreCase))
        {
            var manifest = JsonSerializer.Deserialize<ApplicationManifest>(File.ReadAllText(args[1]), new JsonSerializerOptions(JsonSerializerDefaults.Web))
                ?? throw new InvalidDataException("Manifest is empty.");
            registry.Register(manifest);
            Console.WriteLine($"REGISTERED {manifest.ApplicationId}");
            return 0;
        }

        if (args.Length == 1 && args[0].Equals("list", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var manifest in registry.List())
                Console.WriteLine($"{manifest.ApplicationId}\t{manifest.DisplayName}\t{manifest.Channel}");
            return 0;
        }

        if (args.Length == 2 && args[0].Equals("show", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine(JsonSerializer.Serialize(registry.Get(args[1]), new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
            return 0;
        }

        if (args.Length is 4 or 5 && args[0].Equals("update", StringComparison.OrdinalIgnoreCase))
        {
            var engine = new TransactionalUpdateEngine(registry);
            var state = await engine.ExecuteAsync(new UpdateRequest
            {
                ApplicationId = args[1],
                PackagePath = Path.GetFullPath(args[2]),
                ExpectedSha256 = args[3],
                TargetVersion = args.Length == 5 ? args[4] : null,
                HealthTimeout = ResolveHealthTimeout()
            });
            Console.WriteLine(JsonSerializer.Serialize(state, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
            return 0;
        }

        Console.Error.WriteLine("Usage:");
        Console.Error.WriteLine("  SirkUpdater register <manifest.json>");
        Console.Error.WriteLine("  SirkUpdater list");
        Console.Error.WriteLine("  SirkUpdater show <applicationId>");
        Console.Error.WriteLine("  SirkUpdater update <applicationId> <package.zip> <sha256> [targetVersion]");
        return 2;
    }
    catch (UpdateFailedException error)
    {
        Console.Error.WriteLine(JsonSerializer.Serialize(error.State, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
        return 3;
    }
    catch (Exception error)
    {
        Console.Error.WriteLine(error.Message);
        return 1;
    }
}

static TimeSpan ResolveHealthTimeout()
{
    const int defaultSeconds = 120;
    var raw = Environment.GetEnvironmentVariable("SIRK_UPDATER_HEALTH_TIMEOUT_SECONDS");
    if (string.IsNullOrWhiteSpace(raw)) return TimeSpan.FromSeconds(defaultSeconds);
    if (!int.TryParse(raw, out var seconds) || seconds is < 5 or > 600)
        throw new InvalidDataException("SIRK_UPDATER_HEALTH_TIMEOUT_SECONDS must be between 5 and 600 seconds.");
    return TimeSpan.FromSeconds(seconds);
}
