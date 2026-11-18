using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Azure.Core;
using LogRouter;
using Xunit;

namespace LogRouter.Tests;

public sealed class IngestionTests
{
    [Fact]
    public async Task PostsExpectedEndpointAudienceAndJsonBody()
    {
        var credential = new TestCredential();
        using var handler = new TestHandler(_ => new(HttpStatusCode.NoContent));
        using var client = new HttpClient(handler);
        var destination = RoutingTests.Config().Routes[0].Target;
        var body = Encoding.UTF8.GetBytes("""[{"Payload":{"message":"hello"}}]""");
        await new LogsIngestionSink(client, credential).SendAsync(destination, "Custom-ForwardedActivity_CL", body, default);
        Assert.Equal("https://monitor.azure.com/.default", Assert.Single(credential.Scopes!));
        Assert.Equal(
            "https://test.ingest.monitor.azure.com/dataCollectionRules/dcr-00000000000000000000000000000001/streams/Custom-ForwardedActivity_CL?api-version=2023-01-01",
            handler.Uri!.AbsoluteUri);
        Assert.Equal("Bearer", handler.Authorization!.Scheme);
        Assert.Equal("test-token", handler.Authorization.Parameter);
        Assert.Equal("application/json", handler.ContentType);
        Assert.Equal(body, handler.Body);
    }

    [Fact]
    public async Task ThrottlingAndServerErrorsRetryBeforeSuccess()
    {
        using var handler = new TestHandler(attempt => new(attempt switch
        {
            1 => HttpStatusCode.TooManyRequests,
            2 => HttpStatusCode.ServiceUnavailable,
            _ => HttpStatusCode.NoContent
        }) { Headers = { RetryAfter = new RetryConditionHeaderValue(TimeSpan.Zero) } });
        using var client = new HttpClient(handler);
        await new LogsIngestionSink(client, new TestCredential()).SendAsync(
            RoutingTests.Config().Routes[0].Target, "Custom-ForwardedActivity_CL", "[]"u8.ToArray(), default);
        Assert.Equal(3, handler.Calls);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.RequestEntityTooLarge)]
    public async Task PermanentFailuresDoNotRetry(HttpStatusCode status)
    {
        using var handler = new TestHandler(_ => new(status));
        using var client = new HttpClient(handler);
        var exception = await Assert.ThrowsAsync<DeliveryException>(() => new LogsIngestionSink(client, new TestCredential())
            .SendAsync(RoutingTests.Config().Routes[0].Target, "Custom-ForwardedActivity_CL", "[]"u8.ToArray(), default));
        Assert.Contains(((int)status).ToString(), exception.Message);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task RetriesAreBounded()
    {
        using var handler = new TestHandler(_ => new(HttpStatusCode.ServiceUnavailable)
        {
            Headers = { RetryAfter = new RetryConditionHeaderValue(TimeSpan.Zero) }
        });
        using var client = new HttpClient(handler);
        await Assert.ThrowsAsync<DeliveryException>(() => new LogsIngestionSink(client, new TestCredential())
            .SendAsync(RoutingTests.Config().Routes[0].Target, "Custom-ForwardedActivity_CL", "[]"u8.ToArray(), default));
        Assert.Equal(4, handler.Calls);
    }

    [Fact]
    public async Task LongRetryAfterIsDeferredToDurableReplay()
    {
        using var handler = new TestHandler(_ => new(HttpStatusCode.TooManyRequests)
        {
            Headers = { RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromMinutes(2)) }
        });
        using var client = new HttpClient(handler);
        await Assert.ThrowsAsync<DeliveryException>(() => new LogsIngestionSink(client, new TestCredential())
            .SendAsync(RoutingTests.Config().Routes[0].Target, "Custom-ForwardedActivity_CL", "[]"u8.ToArray(), default));
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task CallerCancellationIsNotSwallowed()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        using var handler = new TestHandler(_ => new(HttpStatusCode.NoContent));
        using var client = new HttpClient(handler);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new LogsIngestionSink(client, new TestCredential())
            .SendAsync(RoutingTests.Config().Routes[0].Target, "Custom-ForwardedActivity_CL", "[]"u8.ToArray(), cancellation.Token));
    }

    private sealed class TestCredential : TokenCredential
    {
        public string[]? Scopes { get; private set; }
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Scopes = requestContext.Scopes;
            return new("test-token", DateTimeOffset.UtcNow.AddHours(1));
        }
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class TestHandler(Func<int, HttpResponseMessage> response) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        public Uri? Uri { get; private set; }
        public AuthenticationHeaderValue? Authorization { get; private set; }
        public string? ContentType { get; private set; }
        public byte[]? Body { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            Uri = request.RequestUri;
            Authorization = request.Headers.Authorization;
            ContentType = request.Content!.Headers.ContentType?.MediaType;
            Body = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            return response(Calls);
        }
    }
}
