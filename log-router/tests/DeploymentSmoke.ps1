[CmdletBinding()]
param(
    [string] $DotnetExecutable = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source,
    [string] $NuGetSource,
    [ValidateSet('Existing', 'PublicFunction', 'New', 'ConfiguredNamespaceExists', 'NamespaceConflict', 'InfrastructureOnly', 'JumpHost', 'JumpHostDirect', 'ReuseNetwork', 'CustomCidrs', 'OverlappingCidrs', 'InvalidJumpHostIp', 'ScmBlocked', 'TableMismatch', 'TenantMismatch', 'RegionMismatch', 'HubMismatch')]
    [string] $Scenario = 'Existing'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$calls = [System.Collections.Generic.List[string[]]]::new()
$testState = @{ CentralChecked = $false; LockedDown = $false; ScmChecked = $false; PackageChecked = $false; ExportChecked = $false; DestinationsChecked = 0 }
$infrastructureOnly = $Scenario -in @('InfrastructureOnly', 'JumpHost', 'JumpHostDirect', 'ReuseNetwork', 'CustomCidrs', 'OverlappingCidrs', 'InvalidJumpHostIp')
$sourceSubscription = '11111111-1111-1111-1111-111111111111'
$routerSubscription = if ($Scenario -eq 'New') { $sourceSubscription } else { '44444444-4444-4444-4444-444444444444' }
$configuredNamespaceName = 'replace-me'
$useConfiguredNamespace = $Scenario -in @('New', 'ConfiguredNamespaceExists', 'NamespaceConflict')
$namespaceName = if ($useConfiguredNamespace) { $configuredNamespaceName } else { 'existing-smoke' }
$vaultId = "/subscriptions/$routerSubscription/resourceGroups/rg-router/providers/Microsoft.KeyVault/vaults/smoke-vault"
$existingVnetId = "/subscriptions/$routerSubscription/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/shared"
$directPassword = [guid]::NewGuid().ToString()

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

function Invoke-WebRequest {
    Check ($testState.CentralChecked) 'SCM probe must follow private infrastructure deployment'
    Check ($args -contains 'https://function-smoke.scm.azurewebsites.net/api/deployments') 'Probe the SCM hostname returned by the template'
    Check ($args -contains '-NoProxy') 'Probe the private endpoint directly'
    $testState.ScmChecked = $true
    @{ StatusCode = if ($Scenario -eq 'ScmBlocked') { 403 } else { 401 } }
}

function Read-Host {
    Check ($Scenario -eq 'JumpHostDirect' -and $args -contains '-AsSecureString') 'Direct password is prompted securely'
    ConvertTo-SecureString $directPassword -AsPlainText -Force
}

function Invoke-RestMethod {
    Check ($Scenario -eq 'JumpHostDirect' -and $testState.CentralChecked) 'Direct deployment follows VNet creation'
    Check ((Arg $args '-Method') -eq 'Put' -and (Arg $args '-Authentication') -eq 'OAuth') 'Use authenticated ARM deployment'
    Check ((Arg $args '-Uri') -eq "https://management.azure.com/subscriptions/$routerSubscription/resourceGroups/rg-router/providers/Microsoft.Resources/deployments/smoke-router-jump?api-version=2022-09-01") 'Send password only to the scoped ARM endpoint'
    $request = (Arg $args '-Body') | ConvertFrom-Json -Depth 100
    Check ($request.properties.mode -eq 'Incremental' -and $request.properties.template.parameters.adminPassword.type -eq 'secureString') 'Use a secure template parameter'
    Check ($request.properties.parameters.adminUsername.value -eq 'deployadmin' -and
        $request.properties.parameters.adminPassword.value -ceq $directPassword) 'Submit the prompted credentials'
    $testState.JumpHostChecked = $true
}

# The deployment script resolves this local function instead of the real Azure CLI.
# Unsupported commands fail closed so this test never provisions Azure resources.
function az {
    $a = [string[]]$args
    Check (!$a.Contains($directPassword)) 'Never pass the direct password to Azure CLI'
    $calls.Add($a)
    $result = @{}
    if (($a[0..1] -join ' ') -eq 'bicep build') {
        Check ($Scenario -eq 'JumpHostDirect' -and (Split-Path (Arg $a '--file') -Leaf) -eq 'jump-host.bicep') 'Compile the jump host template'
        $result = @{ parameters = @{ adminPassword = @{ type = 'secureString' } } }
    }
    elseif (($a[0..1] -join ' ') -eq 'account get-access-token') {
        Check ($Scenario -eq 'JumpHostDirect' -and (Arg $a '--subscription') -eq $routerSubscription) 'Get ARM token in router subscription'
        $result = @{ accessToken = 'mock-arm-token' }
    }
    elseif (($a[0..2] -join ' ') -in @('deployment group wait', 'deployment group show')) {
        Check ($Scenario -eq 'JumpHostDirect' -and $testState.JumpHostChecked -and (Arg $a '--name') -eq 'smoke-router-jump') 'Wait for and read the private-network jump host deployment'
        $result = @{ properties = @{ outputs = @{
            publicIpAddress = @{ value = '203.0.113.9' }
            administrator = @{ value = 'deployadmin' }
        } } }
    }
    elseif (($a[0..2] -join ' ') -eq 'network vnet show') {
        Check ($Scenario -eq 'ReuseNetwork' -and (Arg $a '--resource-group') -eq 'rg-network') 'Look up the selected VNet across resource groups'
        $result = @{
            id = $existingVnetId; location = 'westeurope'
            subnets = @(
                @{ name = 'integration'; id = "$existingVnetId/subnets/integration"; delegations = @(@{ serviceName = 'Microsoft.App/environments' }) }
                @{ name = 'endpoints'; id = "$existingVnetId/subnets/endpoints" }
                @{ name = 'jump'; id = "$existingVnetId/subnets/jump"; delegations = @() }
            )
        }
    }
    elseif (($a[0..1] -join ' ') -eq 'resource list') {
        Check ($useConfiguredNamespace -and (Arg $a '--name') -eq $configuredNamespaceName -and
            (Arg $a '--resource-type') -eq 'Microsoft.EventHub/namespaces' -and
            (Arg $a '--subscription') -eq $routerSubscription) 'Discover the configured namespace in the router subscription'
        $result = @()
        if ($Scenario -ne 'New') {
            $group = if ($Scenario -eq 'NamespaceConflict') { 'rg-other' } else { 'rg-router' }
            $result += @{ name = $namespaceName; id = "/subscriptions/$routerSubscription/resourceGroups/$group/providers/Microsoft.EventHub/namespaces/$namespaceName" }
        }
    }
    elseif (($a[0..1] -join ' ') -eq 'resource show') {
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
        Check ((Arg $a '--name') -eq $namespaceName) 'Inspect only the expected namespace'
        $result = @{
            location = if ($Scenario -eq 'RegionMismatch') { 'eastus' } else { 'westeurope' }
            provisioningState = 'Succeeded'; sku = @{ name = 'Premium' }
            disableLocalAuth = $false
            publicNetworkAccess = if ($Scenario -eq 'ScmBlocked') { 'Disabled' } else { 'Enabled' }
        }
    }
    elseif (($a[0..2] -join ' ') -eq 'eventhubs namespace update') {
        Check ($testState.CentralChecked) 'Disable namespace public access through ARM after central deployment'
        Check ((Arg $a '--public-network-access') -eq 'Disabled') 'Reused namespace must not remain public'
        Check ((Arg $a '--name') -eq $namespaceName) 'Only lock down the selected namespace'
        $testState.LockedDown = $true
        $result = @{ publicNetworkAccess = 'Disabled' }
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
                Check ($p.functionPublicAccess.value -is [bool] -and
                    $p.functionPublicAccess.value -eq ($Scenario -eq 'PublicFunction')) 'Only explicit public Function mode enables inbound public access'
                Check ((Arg $a '--subscription') -eq $routerSubscription) 'Router deployment subscription'
                $expectedNamespace = if ($Scenario -eq 'New') { '' } else { $namespaceName }
                Check ($p.existingEventHubNamespaceName.value -eq $expectedNamespace) 'Correct namespace create/reuse choice'
                $expectedNewNamespace = if ($Scenario -eq 'New') { $configuredNamespaceName } else { '' }
                Check ($p.newEventHubNamespaceName.value -ceq $expectedNewNamespace -and $p.eventHubName.value -eq 'central-logs') 'Use the routing hostname for namespace creation without changing the Event Hub name'
                if ($Scenario -eq 'ReuseNetwork') {
                    Check ($p.existingVnetId.value -eq $existingVnetId -and
                        $p.existingFunctionSubnetId.value -eq "$existingVnetId/subnets/integration" -and
                        $p.existingPrivateEndpointSubnetId.value -eq "$existingVnetId/subnets/endpoints" -and
                        !$p.PSObject.Properties['vnetCidr']) 'Use resolved subnet IDs without sending new network settings'
                }
                if ($Scenario -eq 'CustomCidrs') {
                    Check ($p.vnetCidr.value -eq '10.70.0.0/24' -and $p.functionSubnetCidr.value -eq '10.70.0.0/27' -and
                        $p.privateEndpointSubnetCidr.value -eq '10.70.0.32/28') 'Pass all custom network ranges'
                }
                $testState.CentralChecked = $true
                $result = @{ properties = @{ outputs = @{
                    principalId = @{ value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                    functionAppName = @{ value = 'function-smoke' }
                    storageAccountName = @{ value = 'storagesmoke' }
                    eventHubNamespaceHost = @{ value = "$namespaceName.servicebus.windows.net" }
                    eventHubNamespaceResourceId = @{ value = "/subscriptions/$routerSubscription/resourceGroups/rg-router/providers/Microsoft.EventHub/namespaces/$namespaceName" }
                    functionScmHost = @{ value = 'function-smoke.scm.azurewebsites.net' }
                    routerVnetId = @{ value = if ($Scenario -eq 'ReuseNetwork') { $existingVnetId } else { "/subscriptions/$routerSubscription/resourceGroups/rg-router/providers/Microsoft.Network/virtualNetworks/vnet-smoke" } }
                } } }
            }
            'jump-host.bicep' {
                Check ($Scenario -in @('JumpHost', 'ReuseNetwork', 'CustomCidrs') -and $testState.CentralChecked) 'Jump host is opt-in and follows router network setup'
                $expectedVnetName = if ($Scenario -eq 'ReuseNetwork') { 'shared' } else { 'vnet-smoke' }
                Check ($p.routerVnetName.value -eq $expectedVnetName -and $p.rdpSourceIp.value -eq '203.0.113.8') 'Use the selected VNet and operator address'
                if ($Scenario -eq 'ReuseNetwork') {
                    Check ($p.existingJumpHostSubnetId.value -eq "$existingVnetId/subnets/jump") 'Use existing jump-host subnet'
                }
                if ($Scenario -eq 'CustomCidrs') {
                    Check ($p.jumpHostSubnetCidr.value -eq '10.70.0.64/27') 'Pass the custom jump-host range'
                }
                Check ($p.adminPassword.reference.keyVault.id -eq $vaultId -and
                    $p.adminPassword.reference.secretName -eq 'jump-admin' -and
                    !$p.adminPassword.PSObject.Properties['value']) 'Pass a vault reference and no plaintext password'
                $testState.JumpHostChecked = $true
                $result = @{ properties = @{ outputs = @{
                    publicIpAddress = @{ value = '203.0.113.9' }
                    administrator = @{ value = 'routeradmin' }
                } } }
            }
            'destination.bicep' {
                Check ($testState.CentralChecked -and ($infrastructureOnly -or $testState.ScmChecked)) 'Destinations require central infrastructure; full deploy also requires private SCM reachability'
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
        Check ($testState.ScmChecked -and ($Scenario -eq 'New' -or $testState.LockedDown)) 'Package deployment must follow private network setup'
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
if ($Scenario -eq 'PublicFunction') { $parameters.FunctionAccess = 'Public' }
if ($infrastructureOnly) { $parameters.InfrastructureOnly = $true }
if ($Scenario -eq 'JumpHostDirect') {
    $parameters.JumpHostAdminUsername = 'deployadmin'
    $parameters.JumpHostRdpSourceIp = '203.0.113.8'
}
if ($Scenario -in @('JumpHost', 'ReuseNetwork', 'CustomCidrs', 'InvalidJumpHostIp')) {
    $parameters.JumpHostPasswordVaultId = $vaultId
    $parameters.JumpHostPasswordSecretName = 'jump-admin'
    $parameters.JumpHostRdpSourceIp = if ($Scenario -eq 'InvalidJumpHostIp') { '0.0.0.0/0' } else { '203.0.113.8' }
}
if ($Scenario -eq 'ReuseNetwork') {
    $parameters.ExistingVnetId = $existingVnetId
    $parameters.ExistingFunctionSubnetName = 'integration'
    $parameters.ExistingPrivateEndpointSubnetName = 'endpoints'
    $parameters.ExistingJumpHostSubnetName = 'jump'
}
if ($Scenario -eq 'CustomCidrs') {
    $parameters.VnetCidr = '10.70.0.0/24'
    $parameters.FunctionSubnetCidr = '10.70.0.0/27'
    $parameters.PrivateEndpointSubnetCidr = '10.70.0.32/28'
    $parameters.JumpHostSubnetCidr = '10.70.0.64/27'
}
if ($Scenario -eq 'OverlappingCidrs') { $parameters.PrivateEndpointSubnetCidr = '10.250.0.16/28' }
if ($Scenario -ne 'New') {
    $parameters.RouterSubscriptionId = $routerSubscription
}
if (-not $useConfiguredNamespace) {
    $parameters.ExistingEventHubNamespaceName = $namespaceName
}
if ($Scenario -in @('TableMismatch', 'TenantMismatch', 'RegionMismatch', 'HubMismatch', 'NamespaceConflict', 'OverlappingCidrs', 'InvalidJumpHostIp')) {
    $expectedError = switch ($Scenario) {
        'TenantMismatch' { 'router subscription must be in the same Entra tenant' }
        'RegionMismatch' { 'namespace must be in the source workspace region' }
        'HubMismatch' { 'existing Event Hub does not have' }
        'NamespaceConflict' { 'already exists outside the router resource group' }
        'TableMismatch' { 'does not match source' }
        'InvalidJumpHostIp' { 'must be one IPv4 address' }
        'OverlappingCidrs' { 'overlaps FunctionSubnetCidr' }
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
if ($Scenario -eq 'ScmBlocked') {
    try {
        & (Join-Path $root 'scripts\Deploy.ps1') @parameters
        throw 'Deployment unexpectedly succeeded.'
    }
    catch {
        Check ($_.Exception.Message -like '*private Function deployment endpoint*HTTP 403*') "Unexpected SCM error: $($_.Exception.Message)"
    }
    Check ($testState.ScmChecked -and !$testState.LockedDown -and $testState.DestinationsChecked -eq 0 -and
        !$testState.PackageChecked -and !$testState.ExportChecked) 'SCM failure must stop before destination provisioning, upload, or export'
    Write-Host 'Deployment smoke passed: blocked SCM stopped deployment.'
    return
}
& (Join-Path $root 'scripts\Deploy.ps1') @parameters
if ($infrastructureOnly) {
    Check ($testState.CentralChecked -and $testState.LockedDown -and !$testState.ScmChecked -and $testState.DestinationsChecked -eq 2 -and
        !$testState.PackageChecked -and !$testState.ExportChecked) 'Infrastructure-only must provision both destinations without accessing SCM, deploying code, or configuring export'
    $resolved = Get-Content -LiteralPath (Join-Path $root 'artifacts\routing.deployed.json') -Raw | ConvertFrom-Json
    Check ($resolved.source.eventHubNamespace -eq "$namespaceName.servicebus.windows.net") 'Infrastructure-only must resolve the Event Hubs hostname'
    foreach ($route in $resolved.routes) {
        Check ($route.target.ingestionEndpoint -eq 'https://smoke.ingest.monitor.azure.com/' -and
            $route.target.dcrImmutableId -eq "dcr-$($route.target.subscriptionId.Replace('-', ''))") 'Infrastructure-only must resolve each destination from the DCR deployment outputs'
    }
    Check ($testState.ContainsKey('JumpHostChecked') -eq ($Scenario -ne 'InfrastructureOnly')) 'Only provision a jump host when requested'
    if ($Scenario -eq 'JumpHostDirect') {
        $writtenParameters = Get-ChildItem (Join-Path $root 'artifacts') -Filter '*.parameters.json' -File
        Check (@($writtenParameters | Select-String -SimpleMatch -Pattern $directPassword).Count -eq 0) 'Never write the direct password to an artifact'
    }
    Write-Host "Deployment smoke passed: $Scenario."
    return
}
Check $testState.ExportChecked 'Export deployment must complete'
Check $testState.PackageChecked 'Application package must be verified'
Check ($calls.Count -ge 10) 'Expected command sequence must execute'
Write-Host "Deployment smoke passed: $Scenario, $($calls.Count) mocked Azure commands, two target policies, and a real published ZIP."
