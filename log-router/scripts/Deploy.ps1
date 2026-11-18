[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigurationPath,
    [Parameter(Mandatory)][string] $RouterResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,29}$')][string] $NamePrefix,
    [string] $RouterSubscriptionId = '',
    [string] $ExistingEventHubNamespaceName = '',
    [ValidateRange(1, 40)][int] $ThroughputUnits = 12,
    [string] $NuGetSource
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$configurationPath = (Resolve-Path $ConfigurationPath).Path
$config = Get-Content $configurationPath -Raw | ConvertFrom-Json -Depth 64
$artifacts = Join-Path $root 'artifacts'
New-Item $artifacts -ItemType Directory -Force | Out-Null

function Invoke-AzJson {
    param([string[]] $Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')." }
    if ($result) { return ($result -join "`n" | ConvertFrom-Json -Depth 100) }
}

function ResourceParts([string] $id, [string] $providerType) {
    if ($id -notmatch "^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/$providerType/([^/]+)$") {
        throw "Invalid resource ID: $id"
    }
    return @{ Subscription = $Matches[1]; Group = $Matches[2]; Name = $Matches[3] }
}

function Write-Parameters([string] $name, [hashtable] $values) {
    $parameters = @{}
    foreach ($key in $values.Keys) { $parameters[$key] = @{ value = $values[$key] } }
    $path = Join-Path $artifacts "$name.parameters.json"
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
       contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 64 | Set-Content $path -Encoding utf8
    return $path
}

function Invoke-Dotnet([string[]] $Arguments) {
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'dotnet command failed.' }
}

function Get-TableColumns($schema) {
    # These columns are supplied by Azure, not by the ingestion transform.
    $generated = @('TenantId', 'Type', '_ItemId', '_TimeReceived', '_BilledSize', '_IsBillable', '_SubscriptionId')
    $columns = [ordered]@{}
    foreach ($property in @('columns', 'standardColumns')) {
        if (-not $schema.PSObject.Properties[$property]) { continue }
        foreach ($column in $schema.$property) {
            if ($column.name -in $generated) { continue }
            if ($column.name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                throw "Unsupported source column name: $($column.name)"
            }
            $type = $column.type.ToLowerInvariant()
            if ($type -notin @('string', 'int', 'long', 'real', 'boolean', 'datetime', 'guid', 'dynamic')) {
                throw "Unsupported source column type: $($column.name) ($type)"
            }
            if ($columns.Contains($column.name) -and $columns[$column.name].type -ne $type) {
                throw "Conflicting definitions for column $($column.name)."
            }
            $columns[$column.name] = @{ name = $column.name; type = $type }
        }
    }
    if (-not $columns.Contains('TimeGenerated') -or $columns['TimeGenerated'].type -ne 'datetime') {
        throw "Table $($schema.name) must have a datetime TimeGenerated column."
    }
    return @($columns.Values)
}

function Get-TableProjection([object[]] $columns) {
    $conversions = @{
        string = 'tostring'; int = 'toint'; long = 'tolong'; real = 'toreal'
        boolean = 'tobool'; datetime = 'todatetime'; guid = 'toguid'
    }
    return (($columns | ForEach-Object {
        $field = "Payload['$($_.name)']"
        $expression = if ($_.type -eq 'dynamic') { $field } else { "$($conversions[$_.type])($field)" }
        "['$($_.name)'] = $expression"
    }) -join ', ')
}

Push-Location $root
try {
    $publish = Join-Path $artifacts 'publish'
    # Use a clean staging directory without deleting arbitrary caller-supplied paths.
    if (Test-Path $publish) { throw "Publish staging directory already exists: $publish. Archive/remove that specific directory before redeploying." }
    $buildArgs = @('publish', 'src\LogRouter\LogRouter.csproj', '-c', 'Release', '-o', $publish)
    if ($NuGetSource) { $buildArgs += "-p:RestoreSources=$NuGetSource" }
    Invoke-Dotnet $buildArgs
    $dll = Join-Path $publish 'LogRouter.dll'
    Invoke-Dotnet @($dll, '--validate-config', $configurationPath)

    $source = ResourceParts $config.source.workspaceResourceId 'Microsoft.OperationalInsights/workspaces'
    if ($source.Subscription -ne $config.source.subscriptionId) { throw 'Source subscription mismatch.' }
    $sourceWorkspace = Invoke-AzJson @('resource', 'show', '--ids', $config.source.workspaceResourceId, '--api-version', '2023-09-01')
    $sourceTenant = (Invoke-AzJson @('account', 'show', '--subscription', $source.Subscription)).tenantId
    if (-not $RouterSubscriptionId) { $RouterSubscriptionId = $source.Subscription }
    if ((Invoke-AzJson @('account', 'show', '--subscription', $RouterSubscriptionId)).tenantId -ne $sourceTenant) {
        throw 'The router subscription must be in the same Entra tenant as the source workspace.'
    }
    if ($ExistingEventHubNamespaceName) {
        $namespace = Invoke-AzJson @('eventhubs', 'namespace', 'show', '--subscription', $RouterSubscriptionId,
            '--resource-group', $RouterResourceGroup, '--name', $ExistingEventHubNamespaceName)
        if ($namespace.location -ne $sourceWorkspace.location) {
            throw 'The Event Hubs namespace must be in the source workspace region.'
        }
        if ($namespace.provisioningState -ne 'Succeeded' -or $namespace.sku.name -ne 'Standard' -or
            $namespace.disableLocalAuth -ne $false -or $namespace.publicNetworkAccess -ne 'Enabled') {
            throw 'The existing namespace must be ready, Standard tier, publicly accessible, and have local authorization enabled.'
        }
        $existingHubs = Invoke-AzJson @('eventhubs', 'eventhub', 'list', '--subscription', $RouterSubscriptionId,
            '--resource-group', $RouterResourceGroup, '--namespace-name', $ExistingEventHubNamespaceName)
        foreach ($hub in $existingHubs) {
            if ($hub.name -eq $config.source.eventHubName -and
                ($hub.partitionCount -ne 32 -or $hub.messageRetentionInDays -ne 7)) {
                throw 'The existing Event Hub does not have the managed 32 partitions and 7-day retention; choose a dedicated hub name.'
            }
        }
    }
    $targets = @($config.routes | Group-Object { $_.target.workspaceResourceId.ToLowerInvariant() })
    $sourceSchemas = @{}
    $destinationTables = @{}
    # Validate every destination before deploying any resources.
    foreach ($group in $targets) {
        $route = $group.Group[0]
        $target = ResourceParts $route.target.workspaceResourceId 'Microsoft.OperationalInsights/workspaces'
        $dcr = ResourceParts $route.target.dcrResourceId 'Microsoft.Insights/dataCollectionRules'
        if ($target.Subscription -ne $route.target.subscriptionId -or $dcr.Subscription -ne $target.Subscription -or $dcr.Group -ne $target.Group) {
            throw 'DCR and target workspace must be in the configured target subscription and same resource group.'
        }
        if ((Invoke-AzJson @('account', 'show', '--subscription', $target.Subscription)).tenantId -ne $sourceTenant) {
            throw 'This deployment supports subscriptions in the same Entra tenant only.'
        }
        $null = Invoke-AzJson @('resource', 'show', '--ids', $route.target.workspaceResourceId, '--api-version', '2023-09-01')
        foreach ($item in $group.Group) {
            if ($item.target.dcrResourceId -ne $route.target.dcrResourceId) { throw 'Use one shared DCR per target workspace.' }
        }
        $existingTables = @()
        $tablesUrl = "https://management.azure.com$($route.target.workspaceResourceId)/tables?api-version=2023-09-01"
        do {
            $page = Invoke-AzJson @('rest', '--method', 'get', '--url', $tablesUrl)
            $existingTables += @($page.value)
            $tablesUrl = if ($page.PSObject.Properties['nextLink']) { $page.nextLink } else { $null }
        } while ($tablesUrl)
        foreach ($mapping in @($group.Group.tables | Group-Object targetTable)) {
            $table = $mapping.Group[0]
            if (-not $sourceSchemas.ContainsKey($table.sourceTable)) {
                $definition = Invoke-AzJson @('resource', 'show',
                    '--ids', "$($config.source.workspaceResourceId)/tables/$($table.sourceTable)", '--api-version', '2023-09-01')
                $sourceSchemas[$table.sourceTable] = @(Get-TableColumns $definition.properties.schema)
            }
            $columns = $sourceSchemas[$table.sourceTable]
            $existing = @($existingTables | Where-Object { $_.name -eq $table.targetTable })
            if ($existing.Count -gt 0) {
                $actual = @(Get-TableColumns $existing[0].properties.schema)
                $expectedSignature = @($columns | ForEach-Object { "$($_.name):$($_.type)" } | Sort-Object -CaseSensitive)
                $actualSignature = @($actual | ForEach-Object { "$($_.name):$($_.type)" } | Sort-Object -CaseSensitive)
                if (($expectedSignature -join "`n") -cne ($actualSignature -join "`n")) {
                    throw "Existing target table $($table.targetTable) in $($target.Name) does not match source $($table.sourceTable). No table changes were made; choose a different targetTable."
                }
            }
            $destinationTables["$($route.target.workspaceResourceId)/$($table.targetTable)"] = @{
                createTable = $existing.Count -eq 0
                columns = @($columns | Where-Object { $_.name -ne '_ResourceId' })
                projection = Get-TableProjection $columns
            }
        }
    }

    $null = Invoke-AzJson @('group', 'create', '--subscription', $RouterSubscriptionId,
        '--name', $RouterResourceGroup, '--location', $sourceWorkspace.location)
    $centralParameters = Write-Parameters 'central' @{
        location = $sourceWorkspace.location; namePrefix = $NamePrefix
        eventHubName = $config.source.eventHubName; consumerGroup = $config.source.consumerGroup
        existingEventHubNamespaceName = $ExistingEventHubNamespaceName
        throughputUnits = $ThroughputUnits; routerEnabled = $false
    }
    $central = (Invoke-AzJson @('deployment', 'group', 'create', '--subscription', $RouterSubscriptionId,
        '--resource-group', $RouterResourceGroup, '--name', "$NamePrefix-central",
        '--template-file', (Join-Path $root 'infra\central.bicep'), '--parameters', "@$centralParameters")).properties.outputs
    $config.source.eventHubNamespace = $central.eventHubNamespaceHost.value

    $index = 0
    foreach ($group in $targets) {
        $route = $group.Group[0]
        $target = ResourceParts $route.target.workspaceResourceId 'Microsoft.OperationalInsights/workspaces'
        $dcr = ResourceParts $route.target.dcrResourceId 'Microsoft.Insights/dataCollectionRules'
        $workspace = Invoke-AzJson @('resource', 'show', '--ids', $route.target.workspaceResourceId, '--api-version', '2023-09-01')
        $policies = @($group.Group | ForEach-Object {
            $r = $_
            foreach ($table in $r.tables) {
                [pscustomobject]@{
                    sourceTable = $table.sourceTable; targetTable = $table.targetTable
                    subscriptionOrigin = if ($r.PSObject.Properties['originSubscriptionId']) { $r.originSubscriptionId }
                    tenantOrigin = if ($r.PSObject.Properties['originTenantId']) { $r.originTenantId }
                }
            }
        } | Group-Object targetTable | ForEach-Object {
            $schema = $destinationTables["$($route.target.workspaceResourceId)/$($_.Name)"]
            @{
                sourceTable = $_.Group[0].sourceTable; targetTable = $_.Name
                createTable = $schema.createTable; columns = $schema.columns; projection = $schema.projection
                originSubscriptionIds = @($_.Group | ForEach-Object { if ($_.subscriptionOrigin) { $_.subscriptionOrigin } } | Sort-Object -Unique)
                originTenantIds = @($_.Group | ForEach-Object { if ($_.tenantOrigin) { $_.tenantOrigin } } | Sort-Object -Unique)
            }
        })
        $destinationParameters = Write-Parameters "destination-$index" @{
            workspaceName = $target.Name; workspaceLocation = $workspace.location; dcrName = $dcr.Name
            routerPrincipalId = $central.principalId.value
            sourceWorkspaceResourceId = $config.source.workspaceResourceId; tablePolicies = $policies
        }
        $outputs = (Invoke-AzJson @('deployment', 'group', 'create', '--subscription', $target.Subscription,
            '--resource-group', $target.Group, '--name', "$NamePrefix-destination-$index",
            '--template-file', (Join-Path $root 'infra\destination.bicep'), '--parameters', "@$destinationParameters")).properties.outputs
        foreach ($item in $group.Group) {
            $item.target.dcrResourceId = $outputs.dcrResourceId.value
            $item.target.dcrImmutableId = $outputs.dcrImmutableId.value
            $item.target.ingestionEndpoint = $outputs.ingestionEndpoint.value
        }
        $index++
    }

    $generatedConfig = Join-Path $artifacts 'routing.deployed.json'
    $config | ConvertTo-Json -Depth 64 | Set-Content $generatedConfig -Encoding utf8
    Invoke-Dotnet @($dll, '--validate-config', $generatedConfig)
    Copy-Item $generatedConfig (Join-Path $publish 'routing.json') -Force
    $zip = Join-Path $artifacts ("function-" + [guid]::NewGuid().ToString('N') + '.zip')
    [System.IO.Compression.ZipFile]::CreateFromDirectory($publish, $zip)
    $null = Invoke-AzJson @('functionapp', 'deployment', 'source', 'config-zip',
        '--subscription', $RouterSubscriptionId, '--resource-group', $RouterResourceGroup,
        '--name', $central.functionAppName.value, '--src', $zip, '--build-remote', 'false')
    $null = Invoke-AzJson @('functionapp', 'config', 'appsettings', 'set',
        '--subscription', $RouterSubscriptionId, '--resource-group', $RouterResourceGroup,
        '--name', $central.functionAppName.value, '--settings', 'AzureWebJobs.RouteCentralLogs.Disabled=false')

    $exportTables = @($config.routes | ForEach-Object { $_.tables.sourceTable } | Sort-Object -Unique)
    $exportParameters = Write-Parameters 'export' @{
        workspaceName = $source.Name; eventHubNamespaceResourceId = $central.eventHubNamespaceResourceId.value
        eventHubName = $config.source.eventHubName; tables = $exportTables
    }
    $null = Invoke-AzJson @('deployment', 'group', 'create', '--subscription', $source.Subscription,
        '--resource-group', $source.Group, '--name', "$NamePrefix-export",
        '--template-file', (Join-Path $root 'infra\export.bicep'), '--parameters', "@$exportParameters")
    Write-Host "Deployment finished. Generated configuration: $generatedConfig"
    Write-Host "Function: $($central.functionAppName.value). Quarantine account: $($central.storageAccountName.value)"
    Write-Host 'Verify trigger startup, RBAC propagation, export metrics, and destination row counts before production acceptance.'
}
finally { Pop-Location }
