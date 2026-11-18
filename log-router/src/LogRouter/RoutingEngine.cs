using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LogRouter;

public sealed record Delivery(Route Route, TableRule Table, byte[] Record);
public sealed record RoutingResult(IReadOnlyList<Delivery> Deliveries, string? Rejection, bool Filtered = false);

public sealed class RoutingEngine
{
    private readonly RouterConfiguration configuration;
    private sealed record TableRoutes(TableRule OriginMapping, bool TenantScoped, Dictionary<Guid, (Route Route, TableRule Table)[]> Origins);
    private readonly Dictionary<string, TableRoutes> rules;

    public RoutingEngine(RouterConfiguration configuration)
    {
        configuration.Validate();
        this.configuration = configuration;
        rules = configuration.Routes.SelectMany(r => r.Tables.Select(t => (Route: r, Table: t)))
            .GroupBy(x => x.Table.SourceTable, StringComparer.Ordinal)
            .ToDictionary(g => g.Key,
                g => new TableRoutes(g.First().Table, g.First().Route.OriginTenantId is not null,
                    g.GroupBy(x => (x.Route.OriginSubscriptionId ?? x.Route.OriginTenantId)!.Value)
                    .ToDictionary(origin => origin.Key, origin => origin.ToArray())), StringComparer.Ordinal);
    }

    public RoutingResult RouteRecord(JsonElement record)
    {
        if (record.ValueKind != JsonValueKind.Object) return new([], "Record is not a JSON object.");
        if (!Filter.TryRead(record, "Type", out var type) || type.ValueKind != JsonValueKind.String)
            return new([], "Record has no string Type field.");
        if (!rules.TryGetValue(type.GetString()!, out var tableRules))
            return new([], "Table has no configured route.");
        if (!Filter.TryRead(record, "TimeGenerated", out var time) || time.ValueKind != JsonValueKind.String
            || !DateTimeOffset.TryParse(time.GetString(), CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var timestamp))
            return new([], "Record has no valid TimeGenerated.");
        var (origin, resourceId, error) = ResolveOrigin(record, tableRules.OriginMapping, tableRules.TenantScoped);
        if (error is not null) return new([], error);
        if (!tableRules.Origins.TryGetValue(origin!.Value, out var originRules))
            return new([], $"Origin {(tableRules.TenantScoped ? "tenant" : "subscription")} has no route for this table.");
        var deliveries = new List<Delivery>();
        foreach (var (route, table) in originRules)
        {
            if (table.Filter is not null && !table.Filter.Matches(record)) continue;
            var identity = $"{configuration.Source.WorkspaceResourceId.ToLowerInvariant()}\n"
                + $"{route.Target.WorkspaceResourceId.ToLowerInvariant()}\n{table.TargetTable}\n{record.GetRawText()}";
            var deliveryId = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));
            if (Encoding.UTF8.GetByteCount(record.GetRawText()) > 60_000)
                return new([], "Original record exceeds the conservative 60 KB Payload limit.");
            var output = JsonSerializer.SerializeToUtf8Bytes(new
            {
                TimeGenerated = timestamp.ToUniversalTime(),
                OriginSubscriptionId = tableRules.TenantScoped ? "" : origin!.Value.ToString("D"),
                OriginTenantId = tableRules.TenantScoped ? origin!.Value.ToString("D") : "",
                OriginResourceId = resourceId,
                SourceTable = table.SourceTable,
                SourceWorkspaceResourceId = configuration.Source.WorkspaceResourceId,
                DeliveryId = deliveryId,
                Payload = record
            });
            deliveries.Add(new(route, table, output));
        }
        return deliveries.Count > 0 ? new(deliveries, null) : new([], null, true);
    }

    private static (Guid? Origin, string ResourceId, string? Error) ResolveOrigin(JsonElement record, TableRule table, bool tenantScoped)
    {
        var ids = new HashSet<Guid>();
        var resourceId = "";
        var kind = tenantScoped ? "tenant" : "subscription";
        foreach (var field in tenantScoped ? table.TenantIdFields : table.SubscriptionIdFields)
        {
            if (!Filter.TryRead(record, field, out var value) || value.ValueKind == JsonValueKind.Null
                || (value.ValueKind == JsonValueKind.String && string.IsNullOrWhiteSpace(value.GetString()))) continue;
            if (value.ValueKind != JsonValueKind.String || !Guid.TryParse(value.GetString(), out var id) || id == Guid.Empty)
                return (null, "", $"Invalid originating {kind} in {field}.");
            ids.Add(id);
        }
        foreach (var field in table.ResourceIdFields)
        {
            if (!Filter.TryRead(record, field, out var value) || value.ValueKind == JsonValueKind.Null) continue;
            if (value.ValueKind != JsonValueKind.String) return (null, "", $"Invalid resource ID in {field}.");
            var text = value.GetString()!;
            if (text.Length == 0) continue;
            resourceId = resourceId.Length == 0 ? text : resourceId;
            var parts = text.Split('/');
            if (parts.Length >= 3 && parts[0] == ""
                && parts[1].Equals(tenantScoped ? "tenants" : "subscriptions", StringComparison.OrdinalIgnoreCase))
            {
                if (!Guid.TryParse(parts[2], out var id) || id == Guid.Empty)
                    return (null, "", $"Invalid {kind} segment in {field}.");
                ids.Add(id);
            }
        }
        return ids.Count switch
        {
            1 => (ids.Single(), resourceId, null),
            0 => (null, resourceId, $"No originating {kind} could be resolved."),
            _ => (null, resourceId, $"Conflicting originating {kind} IDs; record quarantined.")
        };
    }

    public static IReadOnlyList<JsonElement> ParseRecords(ReadOnlyMemory<byte> body)
    {
        using var document = JsonDocument.Parse(body);
        var root = document.RootElement;
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("records", out var records))
            root = records;
        if (root.ValueKind == JsonValueKind.Array)
            return root.EnumerateArray().Select(x => x.Clone()).ToArray();
        if (root.ValueKind == JsonValueKind.Object) return [root.Clone()];
        throw new JsonException("Expected a JSON record, record array, or records envelope.");
    }
}
