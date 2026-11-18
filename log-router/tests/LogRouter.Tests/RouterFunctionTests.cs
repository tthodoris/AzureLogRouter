using Azure.Messaging.EventHubs;
using LogRouter;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LogRouter.Tests;

public sealed class RouterFunctionTests
{
    [Theory]
    [InlineData("123", false)]
    [InlineData("123", true)]
    [InlineData(123L, false)]
    [InlineData(123L, true)]
    public async Task HostAndSdkMetadataTypesReachRecordProcessing(object offset, bool useDateTime)
    {
        var config = RoutingTests.Config();
        var failures = new Failures();
        var processor = new DeliveryProcessor(config, new RoutingEngine(config), new Sink(), failures,
            NullLogger<DeliveryProcessor>.Instance);
        var message = new EventData("{");
        message.GetRawAmqpMessage().MessageAnnotations["x-opt-offset"] = offset;
        var time = new DateTimeOffset(2026, 11, 7, 12, 0, 0, TimeSpan.Zero);
        message.GetRawAmqpMessage().MessageAnnotations["x-opt-enqueued-time"] =
            useDateTime ? DateTime.SpecifyKind(time.DateTime, DateTimeKind.Unspecified) : (object)time;
        await new RouterFunction(processor).RunAsync([message], default);
        var failure = Assert.Single(failures.Items);
        Assert.Equal("MalformedMessage", failure.Kind);
        Assert.Contains("/123/", failure.SourceMessageId);
        Assert.EndsWith("/2026-11-07T12:00:00.0000000+00:00", failure.SourceMessageId);
    }

    private sealed class Failures : IFailureStore
    {
        public List<FailureEnvelope> Items { get; } = [];
        public Task SaveAsync(FailureEnvelope failure, CancellationToken cancellationToken)
        {
            Items.Add(failure);
            return Task.CompletedTask;
        }
    }

    private sealed class Sink : IIngestionSink
    {
        public Task SendAsync(Destination destination, string stream, byte[] body, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Malformed message must never reach ingestion.");
    }
}
