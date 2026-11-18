using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LogRouter;

public sealed record SourceWorkspace
{
    public required Guid SubscriptionId { get; init; }
    public required string WorkspaceResourceId { get; init; }
    public required string EventHubNamespace { get; init; }
    public required string EventHubName { get; init; }
    public required string ConsumerGroup { get; init; }
}

public sealed record Destination
{
    public required Guid SubscriptionId { get; init; }
    public required string WorkspaceResourceId { get; init; }
    public required string DcrResourceId { get; init; }
    public required string DcrImmutableId { get; init; }
    public required Uri IngestionEndpoint { get; init; }
}

public sealed record TableRule
{
    public required string SourceTable { get; init; }
    public required string TargetTable { get; init; }
    public required string StreamName { get; init; }
    public string[] SubscriptionIdFields { get; init; } = ["SubscriptionId", "_SubscriptionId"];
    public string[] TenantIdFields { get; init; } = ["AADTenantId"];
    public string[] ResourceIdFields { get; init; } = ["_ResourceId", "ResourceId"];
    public Filter? Filter { get; init; }
}

public sealed record Route
{
    public required string Name { get; init; }
    public Guid? OriginSubscriptionId { get; init; }
    public Guid? OriginTenantId { get; init; }
    public required Destination Target { get; init; }
    public required TableRule[] Tables { get; init; }
}

public sealed record RouterConfiguration
{
    public required SourceWorkspace Source { get; init; }
    public required Route[] Routes { get; init; }
    public int MaxParallelDeliveries { get; init; } = 8;

    public static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true
    };

    public static RouterConfiguration Load(string path)
    {
        var result = JsonSerializer.Deserialize<RouterConfiguration>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidDataException("Routing configuration is empty.");
        result.Validate();
        return result;
    }

    public void Validate()
    {
        Require(Source is not null && Routes is { Length: > 0 }, "Source and at least one route are required.");
        Require(Source!.SubscriptionId != Guid.Empty, "Source subscription is required.");
        ValidateResource(Source.WorkspaceResourceId, Source.SubscriptionId, "Microsoft.OperationalInsights/workspaces");
        Require(!string.IsNullOrWhiteSpace(Source.EventHubNamespace)
            && Source.EventHubNamespace.EndsWith(".servicebus.windows.net", StringComparison.OrdinalIgnoreCase),
            "A public Azure Event Hubs namespace hostname is required.");
        Require(!string.IsNullOrWhiteSpace(Source.EventHubName) && !string.IsNullOrWhiteSpace(Source.ConsumerGroup),
            "Source Event Hub and consumer group are required.");
        Require(MaxParallelDeliveries is >= 1 and <= 32, "MaxParallelDeliveries must be between 1 and 32.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var combinations = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var route in Routes!)
        {
            Require(route is not null, "Routes cannot contain null.");
            Require(!string.IsNullOrWhiteSpace(route!.Name) && names.Add(route.Name), "Route names must be nonempty and unique.");
            Require((route.OriginSubscriptionId is { } subscription && subscription != Guid.Empty && route.OriginTenantId is null)
                || (route.OriginTenantId is { } tenant && tenant != Guid.Empty && route.OriginSubscriptionId is null),
                $"Exactly one nonempty origin subscription or tenant is required for {route.Name}.");
            Require(route.Target is not null && route.Tables is { Length: > 0 }, $"Destination and tables required for {route.Name}.");
            var target = route.Target!;
            Require(target.SubscriptionId != Guid.Empty, $"Target subscription missing for {route.Name}.");
            ValidateResource(target.WorkspaceResourceId, target.SubscriptionId, "Microsoft.OperationalInsights/workspaces");
            ValidateResource(target.DcrResourceId, target.SubscriptionId, "Microsoft.Insights/dataCollectionRules");
            Require(!target.WorkspaceResourceId.Equals(Source.WorkspaceResourceId, StringComparison.OrdinalIgnoreCase),
                "The central workspace cannot be a destination (export loops).");
            Require(Regex.IsMatch(target.DcrImmutableId ?? "", "^dcr-[a-fA-F0-9]{32}$"), "Invalid DCR immutable ID.");
            Require(target.IngestionEndpoint is { IsAbsoluteUri: true }
                && target.IngestionEndpoint.Scheme == "https"
                && target.IngestionEndpoint.IsDefaultPort
                && target.IngestionEndpoint.Host.EndsWith(".ingest.monitor.azure.com", StringComparison.OrdinalIgnoreCase)
                && target.IngestionEndpoint.AbsolutePath == "/"
                && target.IngestionEndpoint.Query.Length == 0
                && target.IngestionEndpoint.Fragment.Length == 0
                && target.IngestionEndpoint.UserInfo.Length == 0, "Invalid public Azure Logs ingestion endpoint.");
            foreach (var table in route.Tables!)
            {
                Require(table is not null, "Table rules cannot contain null.");
                Require(Regex.IsMatch(table!.SourceTable ?? "", "^[A-Za-z][A-Za-z0-9_]{0,99}$"), "Invalid source table.");
                Require(Regex.IsMatch(table.TargetTable ?? "", "^[A-Za-z][A-Za-z0-9_]{0,96}_CL$"), "Destination must be a custom _CL table.");
                Require(table.StreamName == $"Custom-{table.TargetTable}", "StreamName must be Custom-<TargetTable>.");
                Require(table.SubscriptionIdFields is not null && table.TenantIdFields is not null && table.ResourceIdFields is not null
                    && (route.OriginSubscriptionId is not null ? table.SubscriptionIdFields : table.TenantIdFields)
                        .Concat(table.ResourceIdFields).Any()
                    && table.SubscriptionIdFields.Concat(table.TenantIdFields).Concat(table.ResourceIdFields)
                        .All(x => !string.IsNullOrWhiteSpace(x)),
                    "At least one valid origin field is required.");
                Require(combinations.Add($"{(route.OriginSubscriptionId is null ? "tenant" : "subscription")}/{route.OriginSubscriptionId ?? route.OriginTenantId}/{target.WorkspaceResourceId}/{table.SourceTable}"),
                    "Duplicate origin/workspace/table route; combine filters using any/all instead.");
                table.Filter?.Validate();
            }
        }
        foreach (var group in Routes.SelectMany(r => r.Tables.Select(t => (Route: r, Table: t))).GroupBy(x => x.Table.SourceTable, StringComparer.Ordinal))
        {
            var first = group.First();
            Require(group.All(x => (x.Route.OriginTenantId is null) == (first.Route.OriginTenantId is null)
                && x.Table.SubscriptionIdFields.SequenceEqual(first.Table.SubscriptionIdFields, StringComparer.Ordinal)
                && x.Table.TenantIdFields.SequenceEqual(first.Table.TenantIdFields, StringComparer.Ordinal)
                && x.Table.ResourceIdFields.SequenceEqual(first.Table.ResourceIdFields, StringComparer.Ordinal)),
                "Origin kind and field mappings must be identical for a source table across routes.");
        }
        foreach (var group in Routes.SelectMany(r => r.Tables.Select(t => (r.Target.WorkspaceResourceId, Table: t)))
            .GroupBy(x => $"{x.WorkspaceResourceId}/{x.Table.TargetTable}", StringComparer.OrdinalIgnoreCase))
            Require(group.Select(x => x.Table.SourceTable).Distinct(StringComparer.Ordinal).Count() == 1,
                "Each destination table must map to exactly one source table.");
    }

    public static void ValidateResource(string value, Guid subscriptionId, string resourceType)
    {
        Require(value is not null && Regex.IsMatch(value,
            $"^/subscriptions/{subscriptionId:D}/resourceGroups/[^/]+/providers/{Regex.Escape(resourceType)}/[^/]+$",
            RegexOptions.IgnoreCase), $"Resource ID must identify {resourceType} in subscription {subscriptionId:D}.");
    }

    internal static void Require(bool condition, string message)
    {
        if (!condition)
            throw new InvalidDataException(message);
    }
}
