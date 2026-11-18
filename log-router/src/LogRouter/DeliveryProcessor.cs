using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace LogRouter;

public interface IIngestionSink
{
    Task SendAsync(Destination destination, string stream, byte[] body, CancellationToken cancellationToken);
}

public interface IFailureStore
{
    Task SaveAsync(FailureEnvelope failure, CancellationToken cancellationToken);
}

public sealed record FailureEnvelope(
    string Kind, string Reason, string SourceMessageId, string SourceWorkspaceResourceId,
    string? RouteName, string? DestinationWorkspaceResourceId, string? DcrImmutableId,
    string? StreamName, string BodyBase64);

public sealed class DeliveryException(string message) : Exception(message);

public sealed class DeliveryProcessor(
    RouterConfiguration configuration, RoutingEngine engine, IIngestionSink sink,
    IFailureStore failures, ILogger<DeliveryProcessor> logger)
{
    public const int MaxRequestBytes = 900_000;

    public async Task ProcessAsync(IReadOnlyList<(string Id, ReadOnlyMemory<byte> Body)> messages, CancellationToken cancellationToken)
    {
        var deliveries = new List<Delivery>();
        var filtered = 0;
        var rejected = 0;
        foreach (var (id, body) in messages)
        {
            IReadOnlyList<JsonElement> records;
            try { records = RoutingEngine.ParseRecords(body); }
            catch (JsonException)
            {
                await SaveAsync("MalformedMessage", "Invalid JSON export message.", id, null, null, body.ToArray(), cancellationToken);
                rejected++;
                continue;
            }
            for (var index = 0; index < records.Count; index++)
            {
                var result = engine.RouteRecord(records[index]);
                if (result.Rejection is not null)
                {
                    await SaveAsync("RejectedRecord", result.Rejection, $"{id}/{index}", null, null,
                        JsonSerializer.SerializeToUtf8Bytes(records[index]), cancellationToken);
                    rejected++;
                }
                else if (result.Filtered) filtered++;
                else deliveries.AddRange(result.Deliveries);
            }
        }

        var groups = deliveries.GroupBy(x => (x.Route.Name, x.Table.StreamName)).ToArray();
        await Parallel.ForEachAsync(groups,
            new ParallelOptions { MaxDegreeOfParallelism = configuration.MaxParallelDeliveries, CancellationToken = cancellationToken },
            async (group, token) =>
            {
                foreach (var batch in Batch(group))
                {
                    var first = group.First();
                    try { await sink.SendAsync(first.Route.Target, first.Table.StreamName, batch, token); }
                    catch (DeliveryException exception)
                    {
                        await SaveAsync("FailedDelivery", exception.Message,
                            Convert.ToHexStringLower(SHA256.HashData(batch)), first.Route, first.Table, batch, token);
                    }
                }
            });
        logger.LogInformation("Routing batch completed: messages={Messages}, deliveries={Deliveries}, filtered={Filtered}, rejected={Rejected}. Failed deliveries are logged separately.",
            messages.Count, deliveries.Count, filtered, rejected);
    }

    public static IEnumerable<byte[]> Batch(IEnumerable<Delivery> deliveries)
    {
        using var buffer = new MemoryStream();
        buffer.WriteByte((byte)'[');
        foreach (var delivery in deliveries)
        {
            if (delivery.Record.Length + 2 > MaxRequestBytes)
                throw new InvalidDataException("A normalized record exceeds the ingestion batch limit.");
            if (buffer.Length > 1 && buffer.Length + delivery.Record.Length + 2 > MaxRequestBytes)
            {
                buffer.WriteByte((byte)']');
                yield return buffer.ToArray();
                buffer.SetLength(0);
                buffer.WriteByte((byte)'[');
            }
            if (buffer.Length > 1) buffer.WriteByte((byte)',');
            buffer.Write(delivery.Record);
        }
        if (buffer.Length > 1)
        {
            buffer.WriteByte((byte)']');
            yield return buffer.ToArray();
        }
    }

    private async Task SaveAsync(string kind, string reason, string id, Route? route, TableRule? table, byte[] body,
        CancellationToken cancellationToken)
    {
        await failures.SaveAsync(new(kind, reason, id, configuration.Source.WorkspaceResourceId,
            route?.Name, route?.Target.WorkspaceResourceId, route?.Target.DcrImmutableId,
            table?.StreamName, Convert.ToBase64String(body)), cancellationToken);
        logger.LogError("Persisted routing failure: kind={Kind}, source={MessageId}, route={Route}, reason={Reason}.",
            kind, id, route?.Name, reason);
    }
}
