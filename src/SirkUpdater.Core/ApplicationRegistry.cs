using System.Text.Json;

namespace SirkUpdater.Core;

public sealed class ApplicationRegistry
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public ApplicationRegistry(string? root = null)
    {
        Root = Path.GetFullPath(root ?? Path.Combine(PlatformDataRoot(), "applications"));
    }

    public string Root { get; }

    internal static string PlatformDataRoot()
    {
        if (OperatingSystem.IsWindows())
        {
            var common = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            return Path.Combine(common, "SIRK", "Updater");
        }

        return "/var/lib/sirk-updater";
    }

    public ApplicationManifest Register(ApplicationManifest manifest)
    {
        manifest.Validate();
        Directory.CreateDirectory(Root);

        var destination = Path.Combine(Root, manifest.ApplicationId + ".json");
        var temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temporary, JsonSerializer.Serialize(manifest, JsonOptions));
        File.Move(temporary, destination, true);
        return manifest;
    }

    public ApplicationManifest Get(string applicationId)
    {
        var path = Resolve(applicationId);
        if (!File.Exists(path)) throw new FileNotFoundException("Application is not registered.", path);
        var manifest = JsonSerializer.Deserialize<ApplicationManifest>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidDataException("Application manifest is empty.");
        manifest.Validate();
        return manifest;
    }

    public IReadOnlyList<ApplicationManifest> List()
    {
        if (!Directory.Exists(Root)) return [];
        return Directory.EnumerateFiles(Root, "*.json", SearchOption.TopDirectoryOnly)
            .Select(path => JsonSerializer.Deserialize<ApplicationManifest>(File.ReadAllText(path), JsonOptions))
            .Where(manifest => manifest is not null)
            .Select(manifest => manifest!)
            .OrderBy(manifest => manifest.ApplicationId, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private string Resolve(string applicationId)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(applicationId, "^[a-z0-9][a-z0-9._-]{1,63}$"))
            throw new ArgumentException("Invalid applicationId.", nameof(applicationId));
        return Path.Combine(Root, applicationId + ".json");
    }
}
