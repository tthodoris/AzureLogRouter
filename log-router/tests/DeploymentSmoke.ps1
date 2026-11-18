[CmdletBinding()]
param(
    [string] $DotnetExecutable = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source,
    [string] $NuGetSource,
    [ValidateSet('Existing', 'New', 'TableMismatch', 'TenantMismatch', 'RegionMismatch', 'HubMismatch')]
    [string] $Scenario = 'Existing'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$calls = [System.Collections.Generic.List[string[]]]::new()
$testState = @{ PackageChecked = $false; ExportChecked = $false; DestinationsChecked = 0 }
$sourceSubscription = '11111111-1111-1111-1111-111111111111'
$routerSubscription = if ($Scenario -eq 'New') { $sourceSubscription } else { '44444444-4444-4444-4444-444444444444' }
$namespaceName = if ($Scenario -eq 'New') { 'smoke' } else { 'existing-smoke' }

function TableSchema([string] $Name) {
    $field = switch ($Name) {
        'AzureActivity' { 'ActivityStatusValue' }
        'SigninLogs' { 'UserPrincipalName' }
        'AzureDiagnostics' { 'Category' }
        default { throw "Unexpected source table $Name" }
    }
    return @{
        name = $Name
        columns = @(
            @{ name = $field; type = 'string' }
            @{ name = 'Details'; type = 'dynamic' }
            @{ name = 'Count'; type = 'long' }
            @{ name = 'Enabled'; type = 'boolean' }
            @{ name = 'Duration'; type = 'real' }
            @{ name = 'Index'; type = 'int' }
            @{ name = 'CorrelationId'; type = 'guid' }
        )
        standardColumns = @(
            @{ name = 'TimeGenerated'; type = 'dateTime' }
            @{ name = '_ResourceId'; type = 'string' }
            @{ name = 'TenantId'; type = 'guid' }
            @{ name = 'Type'; type = 'string' }
            @{ name = '_BilledSize'; type = 'real' }
        )
    }
}

function Arg([string[]] $Arguments, [string] $Name) {
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Length) { throw "Missing argument $Name" }
    return $Arguments[$index + 1]
}

function Check([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "Deployment smoke check failed: $Message" }
}

function dotnet { & $DotnetExecutable @args }

# The deployment script resolves this local function instead of the real Azure CLI.
# Unsupported commands fail closed so this test never provisions Azure resources.
function az {
    $a = [string[]]$args
    $calls.Add($a)
    $result = @{}
    if (($a[0..1] -join ' ') -eq 'resource show') {
        $result = @{ id = (Arg $a '--ids'); location = 'westeurope' }
        if ($result.id -match '/tables/([^/]+)$') {
            $result.properties = @{ schema = TableSchema $Matches[1] }
        }
    }
    elseif ($a[0] -eq 'rest') {
        Check ((Arg $a '--method') -eq 'get') 'Only read-only table discovery is allowed'
        $url = Arg $a '--url'
        Check ($url -match '^https://management\.azure\.com/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/(law-a|law-b)/tables\?api-version=2023-09-01(&page=2)?$') 'Table discovery must be workspace-scoped'
        $workspace = $Matches[1]
        $tables = @()
        if ($Scenario -ne 'New') {
            $mappings = if ($workspace -eq 'law-a') {
                if ($url.EndsWith('&page=2')) { @{ ForwardedSigninLogs_CL = 'SigninLogs' } }
                else { @{ ForwardedActivity_CL = 'AzureActivity' } }
            } else { @{ ForwardedDiagnostics_CL = 'AzureDiagnostics' } }
            foreach ($name in $mappings.Keys) {
                $schema = TableSchema $mappings[$name]
                $schema.name = $name
                if ($Scenario -eq 'TableMismatch') { $schema.columns[0].type = 'long' }
                $tables += @{ name = $name; properties = @{ schema = $schema; retentionInDays = 90; plan = 'Basic' } }
            }
        }
        $result = @{ value = $tables }
        if ($Scenario -ne 'New' -and $workspace -eq 'law-a' -and !$url.EndsWith('&page=2')) {
            $result.nextLink = "$url&page=2"
        }
    }
    elseif (($a[0..1] -join ' ') -eq 'account show') {
        $tenantId = if ($Scenario -eq 'TenantMismatch' -and (Arg $a '--subscription') -eq $routerSubscription) {
            'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        } else { 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        $result = @{ tenantId = $tenantId }
    }
    elseif (($a[0..2] -join ' ') -eq 'eventhubs namespace show') {
        Check ((Arg $a '--subscription') -eq $routerSubscription) 'Existing namespace subscription'
        Check ((Arg $a '--resource-group') -eq 'rg-router') 'Existing namespace group'
        $result = @{
            location = if ($Scenario -eq 'RegionMismatch') { 'eastus' } else { 'westeurope' }
            provisioningState = 'Succeeded'; sku = @{ name = 'Standard' }
            disableLocalAuth = $false; publicNetworkAccess = 'Enabled'
        }
    }
    elseif (($a[0..2] -join ' ') -eq 'eventhubs eventhub list') {
        $result = @()
        if ($Scenario -eq 'HubMismatch') {
            $result += @{ name = 'central-logs'; partitionCount = 4; messageRetentionInDays = 1 }
        }
    }
    elseif (($a[0..1] -join ' ') -eq 'group create') {
        Check ((Arg $a '--subscription') -eq $routerSubscription) 'Router group subscription'
    }
    elseif (($a[0..2] -join ' ') -eq 'deployment group create') {
        $template = Split-Path (Arg $a '--template-file') -Leaf
        $parameterPath = (Arg $a '--parameters').Substring(1)
        $p = (Get-Content $parameterPath -Raw | ConvertFrom-Json -Depth 64).parameters
        switch ($template) {
            'central.bicep' {
                Check (!$p.routerEnabled.value) 'Trigger must be disabled initially'
                Check ((Arg $a '--subscription') -eq $routerSubscription) 'Router deployment subscription'
                $expectedNamespace = if ($Scenario -eq 'New') { '' } else { 'existing-smoke' }
                Check ($p.existingEventHubNamespaceName.value -eq $expectedNamespace) 'Correct namespace create/reuse choice'
                $result = @{ properties = @{ outputs = @{
                    principalId = @{ value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                    functionAppName = @{ value = 'function-smoke' }
                    storageAccountName = @{ value = 'storagesmoke' }
                    eventHubNamespaceHost = @{ value = "$namespaceName.servicebus.windows.net" }
                    eventHubNamespaceResourceId = @{ value = "/subscriptions/$routerSubscription/resourceGroups/rg-router/providers/Microsoft.EventHub/namespaces/$namespaceName" }
                } } }
            }
            'destination.bicep' {
                $subscription = Arg $a '--subscription'
                $group = Arg $a '--resource-group'
                $policies = @($p.tablePolicies.value)
                $expected = if ($subscription -eq '22222222-2222-2222-2222-222222222222') { 2 } else { 1 }
                Check ($policies.Count -eq $expected) 'Table selection must differ per spoke'
                foreach ($policy in $policies) {
                    Check ($policy.createTable -eq ($Scenario -eq 'New')) 'Existing tables must be excluded from table deployment'
                    $sourceSchema = TableSchema $policy.sourceTable
                    $expectedColumns = @($sourceSchema.columns + @(@{ name = 'TimeGenerated'; type = 'datetime' }) |
                        ForEach-Object { "$($_.name):$($_.type.ToLowerInvariant())" } | Sort-Object)
                    $actualColumns = @($policy.columns | ForEach-Object { "$($_.name):$($_.type)" } | Sort-Object)
                    Check (($actualColumns -join ',') -ceq ($expectedColumns -join ',')) 'Copy every source column and type, without router metadata'
                    Check ($policy.projection.Contains("['TimeGenerated'] = todatetime(Payload['TimeGenerated'])")) 'Project source timestamp'
                    Check ($policy.projection.Contains("['Details'] = Payload['Details']")) 'Preserve dynamic values'
                    Check ($policy.projection.Contains("['Count'] = tolong(Payload['Count'])")) 'Preserve numeric types'
                    Check ($policy.projection.Contains("['Enabled'] = tobool(Payload['Enabled'])")) 'Preserve boolean types'
                    Check ($policy.projection.Contains("['Duration'] = toreal(Payload['Duration'])")) 'Preserve real types'
                    Check ($policy.projection.Contains("['Index'] = toint(Payload['Index'])")) 'Preserve int types'
                    Check ($policy.projection.Contains("['CorrelationId'] = toguid(Payload['CorrelationId'])")) 'GUID transform output must match the declared GUID column type'
                    Check ($policy.projection.Contains("['$($sourceSchema.columns[0].name)'] = tostring(Payload['$($sourceSchema.columns[0].name)'])")) 'Project table-specific source field'
                    Check ($policy.projection.Contains("['_ResourceId'] = tostring(Payload['_ResourceId'])")) 'Preserve resource association'
                    Check (!$policy.projection.Contains("['TenantId']") -and !$policy.projection.Contains("['Type']") -and
                        !$policy.projection.Contains("['DeliveryId']")) 'Do not write generated columns or router metadata'
                    if ($policy.sourceTable -eq 'SigninLogs') {
                        Check (@($policy.originTenantIds).Count -eq 1) 'One tenant origin for sign-in logs'
                        Check ($policy.originTenantIds[0] -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'DCR tenant defense'
                        Check (@($policy.originSubscriptionIds).Count -eq 0) 'No subscription origin for sign-in logs'
                    }
                    else {
                        Check (@($policy.originSubscriptionIds).Count -eq 1) 'One configured subscription origin'
                        Check ($policy.originSubscriptionIds[0] -eq $subscription) 'DCR origin defense must match spoke'
                        Check (@($policy.originTenantIds).Count -eq 0) 'No tenant origin for subscription logs'
                    }
                }
                $testState.DestinationsChecked++
                $result = @{ properties = @{ outputs = @{
                    dcrResourceId = @{ value = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.Insights/dataCollectionRules/$($p.dcrName.value)" }
                    dcrImmutableId = @{ value = "dcr-$($subscription.Replace('-', ''))" }
                    ingestionEndpoint = @{ value = 'https://smoke.ingest.monitor.azure.com/' }
                } } }
            }
            'export.bicep' {
                Check $testState.PackageChecked 'Export must be enabled only after packaging/deployment'
                Check ($testState.DestinationsChecked -eq 2) 'All spokes must be provisioned first'
                Check ((@($p.tables.value | Sort-Object) -join ',') -eq 'AzureActivity,AzureDiagnostics,SigninLogs') 'Export must use table union'
                Check ((Arg $a '--subscription') -eq $sourceSubscription) 'Export must be deployed in source subscription'
                Check ($p.eventHubNamespaceResourceId.value -eq "/subscriptions/$routerSubscription/resourceGroups/rg-router/providers/Microsoft.EventHub/namespaces/$namespaceName") 'Export must target selected namespace'
                $testState.ExportChecked = $true
            }
            default { throw "Unexpected template: $template" }
        }
    }
    elseif (($a[0..4] -join ' ') -eq 'functionapp deployment source config-zip --subscription') {
        Check ((Arg $a '--subscription') -eq $routerSubscription) 'Function ZIP subscription'
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Arg $a '--src'))
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            foreach ($required in @('host.json', 'LogRouter.dll', 'worker.config.json', 'functions.metadata', 'routing.json')) {
                Check ($names -contains $required) "Package must include $required"
            }
            Check (@($names | Where-Object { $_.StartsWith('.azurefunctions/') }).Count -gt 0) 'Extension binaries must be packaged'
            $reader = [System.IO.StreamReader]::new($zip.GetEntry('routing.json').Open())
            try { $configuration = $reader.ReadToEnd() | ConvertFrom-Json -Depth 64 }
            finally { $reader.Dispose() }
            Check ($configuration.source.eventHubNamespace -eq "$namespaceName.servicebus.windows.net") 'Source hub must be resolved'
            Check ($configuration.routes[0].target.ingestionEndpoint -eq 'https://smoke.ingest.monitor.azure.com/') 'DCR endpoint must be resolved'
            Check ($configuration.routes[1].tables[0].filter.value -eq 'example') 'Business filters must survive packaging'
            Check ($configuration.routes[1].originTenantId -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'Tenant origin must survive packaging'
            $testState.PackageChecked = $true
        }
        finally { $zip.Dispose() }
    }
    elseif (($a[0..3] -join ' ') -eq 'functionapp config appsettings set') {
        Check $testState.PackageChecked 'Enable trigger only after deployment'
        Check ((Arg $a '--subscription') -eq $routerSubscription) 'Function settings subscription'
    }
    else { throw "Unmocked Azure command blocked: $($a -join ' ')" }
    $global:LASTEXITCODE = 0
    ConvertTo-Json -InputObject $result -Depth 64 -Compress
}

$parameters = @{
    ConfigurationPath = Join-Path $root 'tests\deployment-routing.json'
    RouterResourceGroup = 'rg-router'
    NamePrefix = 'smoke-router'
}
if ($NuGetSource) { $parameters.NuGetSource = $NuGetSource }
if ($Scenario -ne 'New') {
    $parameters.RouterSubscriptionId = $routerSubscription
    $parameters.ExistingEventHubNamespaceName = $namespaceName
}
if ($Scenario -in @('TableMismatch', 'TenantMismatch', 'RegionMismatch', 'HubMismatch')) {
    $expectedError = switch ($Scenario) {
        'TenantMismatch' { 'router subscription must be in the same Entra tenant' }
        'RegionMismatch' { 'namespace must be in the source workspace region' }
        'HubMismatch' { 'existing Event Hub does not have' }
        'TableMismatch' { 'does not match source' }
    }
    try {
        & (Join-Path $root 'scripts\Deploy.ps1') @parameters
        throw 'Deployment unexpectedly succeeded.'
    }
    catch {
        Check ($_.Exception.Message -like "*$expectedError*") "Expected $Scenario preflight error, got: $($_.Exception.Message)"
    }
    Check (@($calls | Where-Object { $_[0] -eq 'group' -or $_[0] -eq 'deployment' }).Count -eq 0) 'Preflight must fail before Azure changes'
    Write-Host "Deployment smoke passed: $Scenario rejected before Azure changes."
    return
}
& (Join-Path $root 'scripts\Deploy.ps1') @parameters
Check $testState.ExportChecked 'Export deployment must complete'
Check $testState.PackageChecked 'Application package must be verified'
Check ($calls.Count -ge 10) 'Expected command sequence must execute'
Write-Host "Deployment smoke passed: $Scenario, $($calls.Count) mocked Azure commands, two target policies, and a real published ZIP."
