using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using SirkUpdater.Core;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "SIRK Updater");
builder.Services.AddSingleton<ApplicationRegistry>();
builder.Services.AddHostedService<UpdaterWorker>();

await builder.Build().RunAsync();

internal sealed class UpdaterWorker(ApplicationRegistry registry, ILogger<UpdaterWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("SIRK Updater started. Registered applications: {Count}", registry.List().Count);
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            logger.LogDebug("SIRK Updater heartbeat. Registered applications: {Count}", registry.List().Count);
        }
    }
}
