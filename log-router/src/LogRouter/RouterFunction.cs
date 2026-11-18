using Azure.Messaging.EventHubs;
using System.Globalization;
using Microsoft.Azure.Functions.Worker;

namespace LogRouter;

public sealed class RouterFunction(DeliveryProcessor processor)
{
    [Function("RouteCentralLogs")]
    [ExponentialBackoffRetry(-1, "00:00:05", "00:01:00")]
    public Task RunAsync(
        [EventHubTrigger("%ExportHubName%", Connection = "ExportHub", ConsumerGroup = "%ExportConsumerGroup%")]
        EventData[] events,
        CancellationToken cancellationToken)
    {
        var messages = events.Select(e =>
        {
            e.GetRawAmqpMessage().MessageAnnotations.TryGetValue("x-opt-offset", out var offset);
            var offsetText = offset switch
            {
                string text => text,
                long number => number.ToString(CultureInfo.InvariantCulture),
                null => "",
                _ => throw new InvalidDataException("Event Hub offset must be a string or a 64-bit integer.")
            };
            e.GetRawAmqpMessage().MessageAnnotations.TryGetValue("x-opt-enqueued-time", out var enqueuedTime);
            var time = enqueuedTime switch
            {
                DateTimeOffset value => value,
                DateTime value => new DateTimeOffset(value.Kind == DateTimeKind.Unspecified
                    ? DateTime.SpecifyKind(value, DateTimeKind.Utc) : value),
                null => DateTimeOffset.MinValue,
                _ => throw new InvalidDataException("Event Hub enqueue time must be DateTime or DateTimeOffset.")
            };
            return (Id: $"{e.SequenceNumber}/{offsetText}/{time.ToUniversalTime():O}", Body: e.EventBody.ToMemory());
        }).ToArray();
        return processor.ProcessAsync(messages, cancellationToken);
    }
}
