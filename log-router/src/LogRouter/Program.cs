using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using LogRouter;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

if (args is ["--validate-config", var configurationPath])
{
    RouterConfiguration.Load(configurationPath);
    Console.WriteLine("Routing configuration is valid.");
    return;
}

if (args is ["--replay", var replayConfigurationPath, var failurePath])
{
    var configuration = RouterConfiguration.Load(replayConfigurationPath);
    var failure = System.Text.Json.JsonSerializer.Deserialize<FailureEnvelope>(
        File.ReadAllText(failurePath), RouterConfiguration.JsonOptions)
        ?? throw new InvalidDataException("Failure file is empty.");
    if (failure.Kind != "FailedDelivery")
        throw new InvalidDataException("Only FailedDelivery envelopes can be replayed automatically; repair rejected source records manually.");
    var route = configuration.Routes.SingleOrDefault(r => r.Name == failure.RouteName
        && r.Target.WorkspaceResourceId.Equals(failure.DestinationWorkspaceResourceId, StringComparison.OrdinalIgnoreCase))
        ?? throw new InvalidDataException("Failure destination is not in the current routing allowlist.");
    var table = route.Tables.SingleOrDefault(t => t.StreamName == failure.StreamName)
        ?? throw new InvalidDataException("Failure stream is not in the current routing allowlist.");
    var body = Convert.FromBase64String(failure.BodyBase64);
    if (body.Length > DeliveryProcessor.MaxRequestBytes)
        throw new InvalidDataException("Replay batch is too large.");
    using var document = System.Text.Json.JsonDocument.Parse(body);
    if (document.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array || document.RootElement.GetArrayLength() == 0)
        throw new InvalidDataException("Replay body must be a nonempty array.");
    var engine = new RoutingEngine(configuration);
    var approved = new List<Delivery>();
    foreach (var record in document.RootElement.EnumerateArray())
    {
        if (!Filter.TryRead(record, "SourceWorkspaceResourceId", out var source)
            || source.ValueKind != System.Text.Json.JsonValueKind.String
            || !string.Equals(source.GetString(), configuration.Source.WorkspaceResourceId, StringComparison.OrdinalIgnoreCase)
            || !record.TryGetProperty("Payload", out var payload))
            throw new InvalidDataException("Replay record does not belong to this source workspace.");
        var result = engine.RouteRecord(payload);
        var delivery = result.Deliveries.SingleOrDefault(d => d.Route.Name == route.Name && d.Table.StreamName == table.StreamName)
            ?? throw new InvalidDataException("A replay record is rejected by the current origin/table/filter policy.");
        approved.Add(delivery);
    }
    using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(60) };
    var sink = new LogsIngestionSink(client, new DefaultAzureCredential());
    foreach (var batch in DeliveryProcessor.Batch(approved))
        await sink.SendAsync(route.Target, table.StreamName, batch, CancellationToken.None);
    Console.WriteLine($"Replay accepted by ingestion API for route {route.Name}. Verify destination ingestion before archiving the failure blob.");
    return;
}

if (args.Any(argument => argument is "--validate-config" or "--replay"))
    throw new ArgumentException("Supported commands: --validate-config <config>, or --replay <config> <failure-file>.");

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureLogging(logging => logging.AddConsole())
    .ConfigureServices(services =>
    {
        var path = Environment.GetEnvironmentVariable("RoutingConfigPath") ?? "routing.json";
        var configuration = RouterConfiguration.Load(
            Path.IsPathRooted(path) ? path : Path.Combine(AppContext.BaseDirectory, path));
        RequireSetting("ExportHub__fullyQualifiedNamespace", configuration.Source.EventHubNamespace);
        RequireSetting("ExportHubName", configuration.Source.EventHubName);
        RequireSetting("ExportConsumerGroup", configuration.Source.ConsumerGroup);
        var failureUri = Environment.GetEnvironmentVariable("FailureStorageUri")
            ?? throw new InvalidDataException("FailureStorageUri is required.");
        var credential = new DefaultAzureCredential();
        services.AddSingleton(configuration);
        services.AddSingleton<TokenCredential>(credential);
        services.AddSingleton<RoutingEngine>();
        services.AddSingleton<DeliveryProcessor>();
        services.AddSingleton<IFailureStore>(new BlobFailureStore(new BlobContainerClient(new Uri(failureUri), credential)));
        services.AddHttpClient<IIngestionSink, LogsIngestionSink>(client => client.Timeout = TimeSpan.FromSeconds(60))
            .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
    })
    .Build();
await host.RunAsync();

static void RequireSetting(string name, string expected)
{
    if (!string.Equals(Environment.GetEnvironmentVariable(name), expected, StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException($"{name} does not match the configured source. Refusing to consume an unverified export hub.");
}
