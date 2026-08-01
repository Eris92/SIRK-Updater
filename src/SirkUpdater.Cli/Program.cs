using System.Text.Json;
using SirkUpdater.Core;

return await RunAsync(args);

static Task<int> RunAsync(string[] args)
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
            return Task.FromResult(0);
        }

        if (args.Length == 1 && args[0].Equals("list", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var manifest in registry.List())
                Console.WriteLine($"{manifest.ApplicationId}\t{manifest.DisplayName}\t{manifest.Channel}");
            return Task.FromResult(0);
        }

        if (args.Length == 2 && args[0].Equals("show", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine(JsonSerializer.Serialize(registry.Get(args[1]), new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
            return Task.FromResult(0);
        }

        Console.Error.WriteLine("Usage: SirkUpdater register <manifest.json> | list | show <applicationId>");
        return Task.FromResult(2);
    }
    catch (Exception error)
    {
        Console.Error.WriteLine(error.Message);
        return Task.FromResult(1);
    }
}
