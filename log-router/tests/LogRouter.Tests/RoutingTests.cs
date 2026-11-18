using System.Text;
using System.Text.Json;
using Azure.Core;
using LogRouter;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LogRouter.Tests;

public sealed class RoutingTests
{
    private static readonly Guid Central = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid Spoke = Guid.Parse("22222222-2222-2222-2222-222222222222");
    private static readonly Guid Other = Guid.Parse("33333333-3333-3333-3333-333333333333");
    private static readonly Guid Tenant = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");

    internal static RouterConfiguration Config() => new()
    {
        Source = new()
        {
            SubscriptionId = Central,
            WorkspaceResourceId = Workspace(Central, "central"),
            EventHubNamespace = "test.servicebus.windows.net",
            EventHubName = "central-logs",
            ConsumerGroup = "log-router"
        },
        Routes =
        [
            new()
            {
                Name = "spoke-a", OriginSubscriptionId = Spoke,
                Target = new()
                {
                    SubscriptionId = Spoke,
                    WorkspaceResourceId = Workspace(Spoke, "spoke"),
                    DcrResourceId = $"/subscriptions/{Spoke}/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/router",
                    DcrImmutableId = "dcr-00000000000000000000000000000001",
                    IngestionEndpoint = new("https://test.ingest.monitor.azure.com/")
                },
                Tables = [new() { SourceTable = "AzureActivity", TargetTable = "ForwardedActivity_CL", StreamName = "Custom-ForwardedActivity_CL" }]
            }
        ]
    };

    private static string Workspace(Guid subscription, string name) =>
        $"/subscriptions/{subscription}/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/{name}";

    private static JsonElement Json(string value) => JsonDocument.Parse(value).RootElement.Clone();
    private static JsonElement Record(Guid? origin = null, string table = "AzureActivity", string status = "Failed") =>
        JsonSerializer.SerializeToElement(new
        {
            Type = table, SubscriptionId = (origin ?? Spoke).ToString(),
            TimeGenerated = "2026-11-02T10:00:00Z", ActivityStatusValue = status
        });

    private static RouterConfiguration TenantConfig()
    {
        var config = Config();
        var route = config.Routes[0];
        Filter MakeFilter(string name) => JsonSerializer.Deserialize<Filter>(
            $$"""{"field":"UserPrincipalName","op":"contains","value":"{{name}}","ignoreCase":true}""",
            RouterConfiguration.JsonOptions)!;
        var table = route.Tables[0] with
        {
            SourceTable = "SigninLogs", TargetTable = "ForwardedSigninLogs_CL",
            StreamName = "Custom-ForwardedSigninLogs_CL", Filter = MakeFilter("ttsironis")
        };
        var tenantRoute = route with
        {
            OriginSubscriptionId = null, OriginTenantId = Tenant, Tables = [table]
        };
        return config with
        {
            Routes = [tenantRoute, tenantRoute with
            {
                Name = "second",
                Target = tenantRoute.Target with { WorkspaceResourceId = Workspace(Spoke, "second") },
                Tables = [table with { Filter = MakeFilter("gdouka") }]
            }]
        };
    }

    private static JsonElement SignIn(string user, string tenant = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        string? resource = null) =>
        JsonSerializer.SerializeToElement(new
        {
            Type = "SigninLogs", TimeGenerated = "2026-11-02T10:00:00Z",
            AADTenantId = tenant, ResourceId = resource ?? $"/tenants/{Tenant}/providers/Microsoft.aadiam",
            UserPrincipalName = user
        });

    [Theory]
    [InlineData("TTSIRONIS@example.com", "spoke-a")]
    [InlineData("GDouka@example.com", "second")]
    public void TenantScopedSigninUsesCaseInsensitiveFilterAndPreservesOrigin(string user, string route)
    {
        var delivery = Assert.Single(new RoutingEngine(TenantConfig()).RouteRecord(SignIn(user)).Deliveries);
        Assert.Equal(route, delivery.Route.Name);
        var output = Json(Encoding.UTF8.GetString(delivery.Record));
        Assert.Equal(Tenant.ToString(), output.GetProperty("OriginTenantId").GetString());
        Assert.Equal("", output.GetProperty("OriginSubscriptionId").GetString());
        Assert.Equal(user, output.GetProperty("Payload").GetProperty("UserPrincipalName").GetString());
    }

    [Fact]
    public void TenantScopedFiltersDiscardUnmatchedAndAllowExplicitFanout()
    {
        var engine = new RoutingEngine(TenantConfig());
        Assert.True(engine.RouteRecord(SignIn("someone@example.com")).Filtered);
        Assert.Equal(2, engine.RouteRecord(SignIn("ttsironis-gdouka@example.com")).Deliveries.Count);
    }

    [Fact]
    public void TenantResourceIdCanResolveOriginWithoutTenantField()
    {
        var record = Json($$"""
            {"Type":"SigninLogs","TimeGenerated":"2026-11-02T00:00:00Z",
             "ResourceId":"/tenants/{{Tenant}}/providers/Microsoft.aadiam","UserPrincipalName":"ttsironis"}
            """);
        Assert.Single(new RoutingEngine(TenantConfig()).RouteRecord(record).Deliveries);
    }

    [Theory]
    [InlineData("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "/tenants/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/providers/Microsoft.aadiam")]
    [InlineData("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "/tenants/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")]
    [InlineData("invalid", "/tenants/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")]
    [InlineData("", "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg")]
    [InlineData("", "/tenants/not-a-guid/providers/Microsoft.aadiam")]
    public void MissingInvalidConflictingOrUnknownTenantIsRejected(string tenant, string resource)
    {
        var result = new RoutingEngine(TenantConfig()).RouteRecord(SignIn("ttsironis", tenant, resource));
        Assert.NotNull(result.Rejection);
        Assert.Empty(result.Deliveries);
    }

    [Fact]
    public void OriginKindMustBeExplicitUnambiguousAndConsistentPerTable()
    {
        var config = TenantConfig();
        var route = config.Routes[0];
        Assert.Throws<InvalidDataException>(() => (config with
        {
            Routes = [route with { OriginTenantId = null }]
        }).Validate());
        Assert.Throws<InvalidDataException>(() => (config with
        {
            Routes = [route with { OriginTenantId = Guid.Empty }]
        }).Validate());
        Assert.Throws<InvalidDataException>(() => (config with
        {
            Routes = [route with { OriginSubscriptionId = Spoke }]
        }).Validate());
        Assert.Throws<InvalidDataException>(() => (config with
        {
            Routes = [route, route with
            {
                Name = "mixed", OriginTenantId = null, OriginSubscriptionId = Spoke,
                Target = route.Target with { WorkspaceResourceId = Workspace(Spoke, "second") }
            }]
        }).Validate());
    }

    [Fact]
    public void CorrectOriginIsRoutedAndOriginalDataIsPreserved()
    {
        var result = new RoutingEngine(Config()).RouteRecord(Record());
        var delivery = Assert.Single(result.Deliveries);
        var output = Json(delivery.Record is { } data ? Encoding.UTF8.GetString(data) : "");
        Assert.Equal(Spoke.ToString(), output.GetProperty("OriginSubscriptionId").GetString());
        Assert.Equal("", output.GetProperty("OriginTenantId").GetString());
        Assert.Equal("Failed", output.GetProperty("Payload").GetProperty("ActivityStatusValue").GetString());
        Assert.Equal("AzureActivity", output.GetProperty("SourceTable").GetString());
        Assert.Equal(64, output.GetProperty("DeliveryId").GetString()!.Length);
    }

    [Fact]
    public void UnknownOriginNeverFallsBackToAnotherSpoke()
    {
        var result = new RoutingEngine(Config()).RouteRecord(Record(Other));
        Assert.Empty(result.Deliveries);
        Assert.NotNull(result.Rejection);
    }

    [Theory]
    [InlineData("""{"Type":"AzureActivity","TimeGenerated":"2026-11-02T00:00:00Z"}""")]
    [InlineData("""{"Type":"AzureActivity","TimeGenerated":"bad","SubscriptionId":"22222222-2222-2222-2222-222222222222"}""")]
    [InlineData("""{"Type":"AzureActivity","TimeGenerated":"2026-11-02T00:00:00Z","SubscriptionId":"not-a-guid"}""")]
    [InlineData("""{"Type":"UnknownTable","TimeGenerated":"2026-11-02T00:00:00Z","SubscriptionId":"22222222-2222-2222-2222-222222222222"}""")]
    [InlineData("null")]
    public void InvalidOrUnmappedRecordsAreRejected(string json)
    {
        var result = new RoutingEngine(Config()).RouteRecord(Json(json));
        Assert.NotNull(result.Rejection);
        Assert.Empty(result.Deliveries);
    }

    [Fact]
    public void ConflictingResourceSubscriptionIsRejected()
    {
        var record = Json($$"""
            {"Type":"AzureActivity","TimeGenerated":"2026-11-02T00:00:00Z",
             "SubscriptionId":"{{Spoke}}","_ResourceId":"/subscriptions/{{Other}}/resourceGroups/rg"}
            """);
        var result = new RoutingEngine(Config()).RouteRecord(record);
        Assert.Contains("Conflicting", result.Rejection);
        Assert.Empty(result.Deliveries);
    }

    [Fact]
    public void ResourceIdCanResolveOriginWithoutSubscriptionColumn()
    {
        var record = Json($$"""
            {"Type":"AzureActivity","TimeGenerated":"2026-11-02T00:00:00Z",
             "_ResourceId":"/subscriptions/{{Spoke}}/resourceGroups/rg"}
            """);
        Assert.Single(new RoutingEngine(Config()).RouteRecord(record).Deliveries);
    }

    [Fact]
    public void TablesAndFiltersDifferBetweenSubscriptionPairs()
    {
        var config = Config();
        var first = config.Routes[0];
        var second = first with
        {
            Name = "spoke-b", OriginSubscriptionId = Other,
            Target = first.Target with
            {
                SubscriptionId = Other, WorkspaceResourceId = Workspace(Other, "b"),
                DcrResourceId = first.Target.DcrResourceId.Replace(Spoke.ToString(), Other.ToString())
            },
            Tables = [first.Tables[0] with { SourceTable = "AzureDiagnostics" }]
        };
        config = config with
        {
            Routes = [first with
            {
                Tables = [first.Tables[0] with
                {
                    Filter = JsonSerializer.Deserialize<Filter>("""{"field":"ActivityStatusValue","op":"eq","value":"Failed"}""", RouterConfiguration.JsonOptions)
                }]
            }, second]
        };
        var engine = new RoutingEngine(config);
        Assert.Single(engine.RouteRecord(Record()).Deliveries);
        Assert.True(engine.RouteRecord(Record(status: "Succeeded")).Filtered);
        Assert.NotNull(engine.RouteRecord(Record(Other)).Rejection);
        Assert.Equal("spoke-b", Assert.Single(engine.RouteRecord(Record(Other, "AzureDiagnostics")).Deliveries).Route.Name);
    }

    [Fact]
    public void ExplicitFanoutToDistinctWorkspacesIsAllowed()
    {
        var config = Config();
        var second = config.Routes[0] with
        {
            Name = "explicit-copy",
            Target = config.Routes[0].Target with { WorkspaceResourceId = Workspace(Spoke, "second") }
        };
        Assert.Equal(2, new RoutingEngine(config with { Routes = [config.Routes[0], second] }).RouteRecord(Record()).Deliveries.Count);
    }

    [Fact]
    public void TenantRoutesSupportExactPrincipalMatching()
    {
        var config = TenantConfig();
        var route = config.Routes[0];
        var filter = JsonSerializer.Deserialize<Filter>(
            """{"field":"UserPrincipalName","op":"eq","value":"user@example.com","ignoreCase":true}""",
            RouterConfiguration.JsonOptions);
        var engine = new RoutingEngine(config with { Routes = [route with { Tables = [route.Tables[0] with { Filter = filter }] }] });
        Assert.Single(engine.RouteRecord(SignIn("USER@example.com")).Deliveries);
        Assert.True(engine.RouteRecord(SignIn("otheruser@example.com")).Filtered);
    }

    [Theory]
    [InlineData("""{"all":[{"field":"n","op":"ge","value":2},{"field":"nested.state","op":"eq","value":"failed","ignoreCase":true}]}""", true)]
    [InlineData("""{"any":[{"field":"n","op":"lt","value":1},{"field":"nested.state","op":"in","value":["failed"],"ignoreCase":true}]}""", true)]
    [InlineData("""{"not":{"field":"n","op":"eq","value":2}}""", false)]
    [InlineData("""{"field":"missing","op":"ne","value":"x"}""", false)]
    [InlineData("""{"field":"missing","op":"exists"}""", false)]
    [InlineData("""{"field":"nested.state","op":"contains","value":"AIL","ignoreCase":true}""", true)]
    [InlineData("""{"field":"nested.state","op":"startsWith","value":"Fa"}""", true)]
    [InlineData("""{"field":"nested.state","op":"endsWith","value":"ed"}""", true)]
    [InlineData("""{"field":"s","op":"gt","value":1}""", false)]
    [InlineData("""{"field":"nullable","op":"eq","value":null}""", true)]
    [InlineData("""{"field":"nullable","op":"exists"}""", true)]
    public void StructuredFiltersAreStrictAndComposable(string json, bool expected)
    {
        var filter = JsonSerializer.Deserialize<Filter>(json, RouterConfiguration.JsonOptions)!;
        filter.Validate();
        Assert.Equal(expected, filter.Matches(Json("""{"n":2,"s":"2","nested":{"state":"Failed"},"nullable":null}""")));
    }

    [Theory]
    [InlineData("""{"all":[]}""")]
    [InlineData("""{"field":"x","op":"regex","value":"a"}""")]
    [InlineData("""{"field":"x","op":"in","value":"a"}""")]
    [InlineData("""{"field":"x","op":"gt","value":"2"}""")]
    [InlineData("""{"field":"x","op":"eq"}""")]
    [InlineData("""{"field":"x","op":"exists","value":true}""")]
    [InlineData("""{"all":[null]}""")]
    [InlineData("""{"not":{"field":"x","op":"exists"},"op":"eq"}""")]
    public void InvalidFiltersFailBeforeConsumption(string json)
    {
        var filter = JsonSerializer.Deserialize<Filter>(json, RouterConfiguration.JsonOptions)!;
        Assert.Throws<InvalidDataException>(filter.Validate);
    }

    [Fact]
    public void DuplicateRoutesAndCentralDestinationsAreRejected()
    {
        var config = Config();
        Assert.Throws<InvalidDataException>(() => (config with
        {
            Routes = [config.Routes[0], config.Routes[0] with { Name = "duplicate" }]
        }).Validate());
        var target = config.Routes[0].Target with
        {
            SubscriptionId = Central, WorkspaceResourceId = config.Source.WorkspaceResourceId,
            DcrResourceId = config.Routes[0].Target.DcrResourceId.Replace(Spoke.ToString(), Central.ToString())
        };
        Assert.Throws<InvalidDataException>(() => (config with { Routes = [config.Routes[0] with { Target = target }] }).Validate());
    }

    [Theory]
    [InlineData("http://test.ingest.monitor.azure.com/")]
    [InlineData("https://attacker.example/")]
    [InlineData("https://test.ingest.monitor.azure.com/extra")]
    [InlineData("https://test.ingest.monitor.azure.com/?a=b")]
    public void InvalidEndpointsAreRejected(string endpoint)
    {
        var config = Config();
        Assert.Throws<InvalidDataException>(() => (config with
        {
            Routes = [config.Routes[0] with { Target = config.Routes[0].Target with { IngestionEndpoint = new(endpoint) } }]
        }).Validate());
    }

    [Fact]
    public void ParseAcceptsSupportedExportEnvelopes()
    {
        var record = Record().GetRawText();
        foreach (var json in new[] { record, $"[{record}]", $$"""{"records":[{{record}}]}""" })
            Assert.Single(RoutingEngine.ParseRecords(Encoding.UTF8.GetBytes(json)));
        Assert.Throws<JsonException>(() => RoutingEngine.ParseRecords(Encoding.UTF8.GetBytes("""{"records":null}""")));
    }

    [Fact]
    public void StableDeliveryIdSurvivesReprocessing()
    {
        var engine = new RoutingEngine(Config());
        Assert.Equal(engine.RouteRecord(Record()).Deliveries[0].Record, engine.RouteRecord(Record()).Deliveries[0].Record);
    }

    [Fact]
    public void LargeOriginalRecordIsQuarantinedInsteadOfTruncated()
    {
        var record = JsonSerializer.SerializeToElement(new
        {
            Type = "AzureActivity", SubscriptionId = Spoke.ToString(),
            TimeGenerated = "2026-11-02T00:00:00Z", Data = new string('x', 60_001)
        });
        Assert.Contains("60 KB", new RoutingEngine(Config()).RouteRecord(record).Rejection);
    }

    [Fact]
    public void BatchesStayBelowExactApiByteLimit()
    {
        var config = Config();
        var record = JsonSerializer.SerializeToUtf8Bytes(new { data = new string('x', 50_000) });
        var deliveries = Enumerable.Range(0, 40).Select(_ => new Delivery(config.Routes[0], config.Routes[0].Tables[0], record));
        var batches = DeliveryProcessor.Batch(deliveries).ToArray();
        Assert.True(batches.Length > 1);
        Assert.All(batches, body => Assert.InRange(body.Length, 2, DeliveryProcessor.MaxRequestBytes));
        Assert.Equal(40, batches.Sum(body => JsonDocument.Parse(body).RootElement.GetArrayLength()));
    }

    [Fact]
    public async Task FailedDestinationIsPersistedAndOtherSpokeStillReceives()
    {
        var config = Config();
        config = config with
        {
            Routes = [config.Routes[0], config.Routes[0] with
            {
                Name = "second",
                Target = config.Routes[0].Target with { WorkspaceResourceId = Workspace(Spoke, "second") }
            }]
        };
        var sink = new FakeSink { FailedWorkspace = config.Routes[0].Target.WorkspaceResourceId };
        var failures = new FakeFailures();
        await Processor(config, sink, failures).ProcessAsync([("event-1", Encoding.UTF8.GetBytes(Record().GetRawText()))], default);
        var failure = Assert.Single(failures.Items);
        Assert.Equal("FailedDelivery", failure.Kind);
        Assert.Equal("spoke-a", failure.RouteName);
        Assert.Equal(1, sink.Accepted);
    }

    [Fact]
    public async Task FailureStoreOutageEscapesSoHostCannotCheckpoint()
    {
        var config = Config();
        var sink = new FakeSink { FailedWorkspace = config.Routes[0].Target.WorkspaceResourceId };
        await Assert.ThrowsAsync<IOException>(() => Processor(config, sink, new FakeFailures { Unavailable = true })
            .ProcessAsync([("event-1", Encoding.UTF8.GetBytes(Record().GetRawText()))], default));
    }

    [Fact]
    public async Task MalformedAndUnmappedMessagesAreDurablyRejected()
    {
        var failures = new FakeFailures();
        await Processor(Config(), new FakeSink(), failures).ProcessAsync(
            [("bad", Encoding.UTF8.GetBytes("{")), ("unmapped", Encoding.UTF8.GetBytes(Record(Other).GetRawText()))], default);
        Assert.Equal(2, failures.Items.Count);
        Assert.Contains(failures.Items, f => f.Kind == "MalformedMessage");
        Assert.Contains(failures.Items, f => f.Kind == "RejectedRecord");
    }

    [Fact]
    public async Task CancellationIsNotConvertedToSuccessfulQuarantine()
    {
        var failures = new FakeFailures();
        var sink = new FakeSink { Cancel = true };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Processor(Config(), sink, failures).ProcessAsync(
            [("event-1", Encoding.UTF8.GetBytes(Record().GetRawText()))], default));
        Assert.Empty(failures.Items);
    }

    private static DeliveryProcessor Processor(RouterConfiguration config, IIngestionSink sink, IFailureStore failures) =>
        new(config, new RoutingEngine(config), sink, failures, NullLogger<DeliveryProcessor>.Instance);

    private sealed class FakeSink : IIngestionSink
    {
        public string? FailedWorkspace { get; init; }
        public bool Cancel { get; init; }
        public int Accepted;
        public Task SendAsync(Destination destination, string stream, byte[] body, CancellationToken cancellationToken)
        {
            if (Cancel) throw new OperationCanceledException();
            if (destination.WorkspaceResourceId == FailedWorkspace) throw new DeliveryException("HTTP 403");
            Interlocked.Increment(ref Accepted);
            return Task.CompletedTask;
        }
    }

    private sealed class FakeFailures : IFailureStore
    {
        public bool Unavailable { get; init; }
        public List<FailureEnvelope> Items { get; } = [];
        public Task SaveAsync(FailureEnvelope failure, CancellationToken cancellationToken)
        {
            if (Unavailable) throw new IOException("Storage unavailable.");
            lock (Items) Items.Add(failure);
            return Task.CompletedTask;
        }
    }
}
