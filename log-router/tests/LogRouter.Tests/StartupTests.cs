using System.Diagnostics;
using System.Text.Json;
using LogRouter;
using Xunit;

namespace LogRouter.Tests;

public sealed class StartupTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task WorkerStartupArgumentsReachConfigurationValidation(bool includeWorkerArguments)
    {
        var path = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(path, JsonSerializer.Serialize(RoutingTests.Config(), RouterConfiguration.JsonOptions));
            var arguments = includeWorkerArguments
                ? new[] { "--host", "127.0.0.1", "--port", "12345", "--workerId", "test-worker", "--requestId", "test-request", "--grpcMaxMessageLength", "2147483647" }
                : [];
            var result = await RunAsync(arguments, path);
            Assert.NotEqual(0, result.ExitCode);
            Assert.Contains("ExportHub__fullyQualifiedNamespace does not match", result.Error);
            Assert.DoesNotContain("Supported commands:", result.Error);
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData("--validate-config")]
    [InlineData("--replay")]
    public async Task MalformedMaintenanceCommandsStillFailExplicitly(string command)
    {
        var result = await RunAsync([command], "");
        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("Supported commands:", result.Error);
    }

    private static async Task<(int ExitCode, string Error)> RunAsync(string[] arguments, string configurationPath)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
        {
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            UseShellExecute = false
        };
        start.ArgumentList.Add("exec");
        start.ArgumentList.Add("--runtimeconfig");
        start.ArgumentList.Add(Path.ChangeExtension(typeof(StartupTests).Assembly.Location, ".runtimeconfig.json"));
        start.ArgumentList.Add("--depsfile");
        start.ArgumentList.Add(Path.ChangeExtension(typeof(StartupTests).Assembly.Location, ".deps.json"));
        start.ArgumentList.Add(typeof(RouterConfiguration).Assembly.Location);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["RoutingConfigPath"] = configurationPath;
        start.Environment["ExportHub__fullyQualifiedNamespace"] = "deliberately-mismatched.servicebus.windows.net";
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Unable to launch worker startup test.");
        var error = process.StandardError.ReadToEndAsync();
        var output = process.StandardOutput.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw;
        }
        await output;
        return (process.ExitCode, await error);
    }
}
