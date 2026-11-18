using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Storage.Blobs;

namespace LogRouter;

public sealed class LogsIngestionSink(HttpClient client, TokenCredential credential) : IIngestionSink
{
    private static readonly TokenRequestContext TokenContext = new(["https://monitor.azure.com/.default"]);

    public async Task SendAsync(Destination destination, string stream, byte[] body, CancellationToken cancellationToken)
    {
        var uri = new Uri(destination.IngestionEndpoint,
            $"dataCollectionRules/{Uri.EscapeDataString(destination.DcrImmutableId)}/streams/{Uri.EscapeDataString(stream)}?api-version=2023-01-01");
        for (var attempt = 0; attempt < 4; attempt++)
        {
            var token = await credential.GetTokenAsync(TokenContext, cancellationToken);
            using var request = new HttpRequestMessage(HttpMethod.Post, uri);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
            request.Content = new ByteArrayContent(body);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            TimeSpan delay;
            try
            {
                using var response = await client.SendAsync(request, cancellationToken);
                if (response.IsSuccessStatusCode) return;
                var status = (int)response.StatusCode;
                if (response.StatusCode != HttpStatusCode.RequestTimeout && status != 429 && status < 500)
                    throw new DeliveryException($"Ingestion rejected with HTTP {status}; inspect DCR, schema, and RBAC.");
                if (attempt == 3)
                    throw new DeliveryException($"Ingestion retries exhausted with HTTP {status}.");
                delay = response.Headers.RetryAfter?.Delta
                    ?? (response.Headers.RetryAfter?.Date is { } date ? date - DateTimeOffset.UtcNow : TimeSpan.FromSeconds(Math.Pow(2, attempt)));
            }
            catch (HttpRequestException) when (!cancellationToken.IsCancellationRequested)
            {
                if (attempt == 3) throw new DeliveryException("Ingestion network retries exhausted.");
                delay = TimeSpan.FromSeconds(Math.Pow(2, attempt));
            }
            catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                if (attempt == 3) throw new DeliveryException("Ingestion request timeouts exhausted.");
                delay = TimeSpan.FromSeconds(Math.Pow(2, attempt));
            }
            // Long throttles are persisted for later replay rather than blocking a partition indefinitely.
            if (delay > TimeSpan.FromSeconds(30))
                throw new DeliveryException("Ingestion requested a retry delay over 30 seconds; replay this batch later.");
            await Task.Delay(delay < TimeSpan.Zero ? TimeSpan.Zero : delay, cancellationToken);
        }
    }
}

public sealed class BlobFailureStore(BlobContainerClient container) : IFailureStore
{
    public async Task SaveAsync(FailureEnvelope failure, CancellationToken cancellationToken)
    {
        var content = JsonSerializer.SerializeToUtf8Bytes(failure, RouterConfiguration.JsonOptions);
        var hash = Convert.ToHexStringLower(SHA256.HashData(content));
        var blob = container.GetBlobClient($"{failure.Kind}/{hash}.json");
        try { await blob.UploadAsync(new BinaryData(content), overwrite: false, cancellationToken); }
        catch (RequestFailedException exception) when (exception.Status == 409 && exception.ErrorCode == "BlobAlreadyExists")
        {
            // Identical failures are already durable, including after an Event Hubs batch retry.
        }
    }
}
