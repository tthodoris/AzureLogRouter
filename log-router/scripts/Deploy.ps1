[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigurationPath,
    [Parameter(Mandatory)][string] $RouterResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,29}$')][string] $NamePrefix,
    [string] $RouterSubscriptionId = '',
    [string] $ExistingEventHubNamespaceName = '',
    [switch] $InfrastructureOnly,
    [string] $ExistingVnetId,
    [string] $ExistingFunctionSubnetName,
    [string] $ExistingPrivateEndpointSubnetName,
    [string] $ExistingJumpHostSubnetName,
    [string] $VnetCidr = '10.250.0.0/24',
    [string] $FunctionSubnetCidr = '10.250.0.0/27',
    [string] $PrivateEndpointSubnetCidr = '10.250.0.32/28',
    [string] $JumpHostSubnetCidr = '10.250.0.64/27',
    [string] $JumpHostRdpSourceIp,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,19}$')][string] $JumpHostAdminUsername,
    [securestring] $JumpHostAdminPassword,
    [string] $JumpHostPasswordVaultId,
    [ValidatePattern('^[a-zA-Z0-9-]{1,127}$')][string] $JumpHostPasswordSecretName,
    [ValidateRange(1, 40)][int] $ThroughputUnits = 12,
    [string] $NuGetSource
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$useJumpHostVault = [bool]($JumpHostPasswordVaultId -or $JumpHostPasswordSecretName)
$createJumpHost = [bool]($JumpHostRdpSourceIp -or $JumpHostAdminUsername -or $JumpHostAdminPassword -or $useJumpHostVault)
if ($createJumpHost) {
    if (-not $JumpHostRdpSourceIp) {
        throw 'Creating the jump host requires an RDP source IPv4 address.'
    }
    if ($useJumpHostVault -and (-not ($JumpHostPasswordVaultId -and $JumpHostPasswordSecretName) -or $null -ne $JumpHostAdminPassword)) {
        throw 'Supply both Key Vault options with no direct password, or omit both Key Vault options and use an administrator username and password.'
    }
    if (-not $useJumpHostVault -and -not $JumpHostAdminUsername) {
        throw 'Supply -JumpHostAdminUsername to create a jump host without Key Vault.'
    }
    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($JumpHostRdpSourceIp, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsedIp.ToString() -cne $JumpHostRdpSourceIp -or
        $JumpHostRdpSourceIp -eq '0.0.0.0') {
        throw 'JumpHostRdpSourceIp must be one IPv4 address, without a CIDR suffix.'
    }
}
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

function Get-Ipv4CidrRange([string] $cidr, [int] $maxPrefix, [string] $parameterName) {
    $address = $null
    if ($cidr -notmatch '^([^/]+)/([0-9]{1,2})$' -or
        -not [System.Net.IPAddress]::TryParse($Matches[1], [ref]$address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $address.ToString() -cne $Matches[1] -or [int]$Matches[2] -gt $maxPrefix) {
        throw "$parameterName must be an IPv4 CIDR with a prefix no longer than /$maxPrefix."
    }
    $size = [long]1 -shl (32 - [int]$Matches[2])
    $start = [long]0
    foreach ($octet in $address.GetAddressBytes()) { $start = ($start -shl 8) + $octet }
    if ($start % $size -ne 0) { throw "$parameterName must start at the CIDR network address: $cidr." }
    return @{ Start = $start; End = $start + $size - 1; Name = $parameterName }
}

$networkParameters = @{}
$vnetParts = $null
if ($ExistingVnetId) {
    foreach ($parameterName in @('VnetCidr', 'FunctionSubnetCidr', 'PrivateEndpointSubnetCidr', 'JumpHostSubnetCidr')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) { throw "Do not combine -$parameterName with -ExistingVnetId." }
    }
    if (-not ($ExistingFunctionSubnetName -and $ExistingPrivateEndpointSubnetName) -or
        ($createJumpHost -and -not $ExistingJumpHostSubnetName)) {
        throw 'An existing VNet requires Function and private endpoint subnet names, plus a jump-host subnet name if creating the VM.'
    }
    $names = @($ExistingFunctionSubnetName, $ExistingPrivateEndpointSubnetName)
    if ($ExistingJumpHostSubnetName) { $names += $ExistingJumpHostSubnetName }
    if (@($names | Sort-Object -Unique).Count -ne $names.Count) { throw 'Existing subnets must be distinct.' }
    $vnetParts = ResourceParts $ExistingVnetId 'Microsoft.Network/virtualNetworks'
}
else {
    if ($ExistingFunctionSubnetName -or $ExistingPrivateEndpointSubnetName -or $ExistingJumpHostSubnetName) {
        throw 'Existing subnet names require -ExistingVnetId.'
    }
    $vnetRange = Get-Ipv4CidrRange $VnetCidr 27 'VnetCidr'
    $subnetRanges = @(
        Get-Ipv4CidrRange $FunctionSubnetCidr 27 'FunctionSubnetCidr'
        Get-Ipv4CidrRange $PrivateEndpointSubnetCidr 29 'PrivateEndpointSubnetCidr'
    )
    if ($createJumpHost -or $PSBoundParameters.ContainsKey('JumpHostSubnetCidr')) {
        $subnetRanges += Get-Ipv4CidrRange $JumpHostSubnetCidr 29 'JumpHostSubnetCidr'
    }
    $previous = $null
    foreach ($subnetRange in ($subnetRanges | Sort-Object { $_.Start })) {
        if ($subnetRange.Start -lt $vnetRange.Start -or $subnetRange.End -gt $vnetRange.End) {
            throw "$($subnetRange.Name) must be inside VnetCidr."
        }
        if ($previous -and $subnetRange.Start -le $previous.End) {
            throw "$($subnetRange.Name) overlaps $($previous.Name)."
        }
        $previous = $subnetRange
    }
    $networkParameters = @{
        vnetCidr = $VnetCidr; functionSubnetCidr = $FunctionSubnetCidr; privateEndpointSubnetCidr = $PrivateEndpointSubnetCidr
    }
}

function Get-ExistingSubnet($vnet, [string] $name, [bool] $forFunctions) {
    $matchesByName = @(if ($vnet.PSObject.Properties['subnets']) { $vnet.subnets | Where-Object name -eq $name })
    if ($matchesByName.Count -ne 1) { throw "Subnet '$name' was not found in the selected VNet." }
    $subnet = $matchesByName[0]
    $delegations = @(if ($subnet.PSObject.Properties['delegations'] -and $subnet.delegations) {
        $subnet.delegations | ForEach-Object { $_.serviceName }
    })
    if ($forFunctions -and ($delegations.Count -ne 1 -or $delegations[0] -ne 'Microsoft.App/environments')) {
        throw "Function subnet '$name' must be delegated to Microsoft.App/environments."
    }
    if (-not $forFunctions -and $delegations.Count -gt 0) { throw "Subnet '$name' must not be delegated." }
    return $subnet.id
}

if ($useJumpHostVault) {
    $null = ResourceParts $JumpHostPasswordVaultId 'Microsoft.KeyVault/vaults'
}

function Write-Parameters([string] $name, [hashtable] $values) {
    $parameters = @{}
    foreach ($key in $values.Keys) {
        $parameters[$key] = @{ value = $values[$key] }
    }
    Write-ParameterEntries $name $parameters
}

function Write-ParameterEntries([string] $name, [hashtable] $parameters) {
    $path = Join-Path $artifacts "$name.parameters.json"
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
       contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 64 | Set-Content $path -Encoding utf8
    return $path
}

function Deploy-JumpHostWithPassword([string] $templatePath, [string] $deploymentName, [hashtable] $parameters) {
    $template = Invoke-AzJson @('bicep', 'build', '--file', $templatePath, '--stdout')
    $access = Invoke-AzJson @('account', 'get-access-token', '--subscription', $RouterSubscriptionId, '--resource-type', 'arm')
    $token = ConvertTo-SecureString $access.accessToken -AsPlainText -Force
    $group = [uri]::EscapeDataString($RouterResourceGroup)
    $uri = "https://management.azure.com/subscriptions/$RouterSubscriptionId/resourceGroups/$group/providers/Microsoft.Resources/deployments/${deploymentName}?api-version=2022-09-01"
    # Keep the secure ARM parameter out of parameter files and native command arguments.
    try {
        $parameters.adminPassword = @{ value = (ConvertFrom-SecureString $JumpHostAdminPassword -AsPlainText) }
        $body = @{ properties = @{ mode = 'Incremental'; template = $template; parameters = $parameters } } |
            ConvertTo-Json -Depth 100 -Compress
        $null = Invoke-RestMethod -Method Put -Uri $uri -Authentication OAuth -Token $token `
            -ContentType 'application/json' -Body $body -MaximumRedirection 0
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        $status = [int]$_.Exception.Response.StatusCode
        throw "Azure rejected jump-host deployment '$deploymentName' (HTTP $status). Check the resource group's deployment details."
    }
    finally {
        $parameters.Remove('adminPassword')
        $body = $null
        $token.Dispose()
    }
    $scope = @('--subscription', $RouterSubscriptionId, '--resource-group', $RouterResourceGroup, '--name', $deploymentName)
    $null = Invoke-AzJson (@('deployment', 'group', 'wait', '--created') + $scope)
    return (Invoke-AzJson (@('deployment', 'group', 'show') + $scope)).properties.outputs
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
    if (-not $InfrastructureOnly) {
        if (Test-Path $publish) { throw "Publish staging directory already exists: $publish. Archive/remove that specific directory before redeploying." }
        $project = Join-Path (Join-Path $root 'src') 'LogRouter/LogRouter.csproj'
        $buildArgs = @('publish', $project, '-c', 'Release', '-o', $publish)
        if ($NuGetSource) { $buildArgs += "-p:RestoreSources=$NuGetSource" }
        Invoke-Dotnet $buildArgs
        $dll = Join-Path $publish 'LogRouter.dll'
        Invoke-Dotnet @($dll, '--validate-config', $configurationPath)
    }

    $source = ResourceParts $config.source.workspaceResourceId 'Microsoft.OperationalInsights/workspaces'
    if ($source.Subscription -ne $config.source.subscriptionId) { throw 'Source subscription mismatch.' }
    $sourceWorkspace = Invoke-AzJson @('resource', 'show', '--ids', $config.source.workspaceResourceId, '--api-version', '2023-09-01')
    $sourceTenant = (Invoke-AzJson @('account', 'show', '--subscription', $source.Subscription)).tenantId
    if (-not $RouterSubscriptionId) { $RouterSubscriptionId = $source.Subscription }
    if ((Invoke-AzJson @('account', 'show', '--subscription', $RouterSubscriptionId)).tenantId -ne $sourceTenant) {
        throw 'The router subscription must be in the same Entra tenant as the source workspace.'
    }
    $existingJumpHostSubnetId = ''
    if ($vnetParts) {
        if ($vnetParts.Subscription -ne $RouterSubscriptionId) { throw 'The existing VNet must be in the router subscription.' }
        $vnet = Invoke-AzJson @('network', 'vnet', 'show', '--subscription', $RouterSubscriptionId,
            '--resource-group', $vnetParts.Group, '--name', $vnetParts.Name)
        if ($vnet.location -ne $sourceWorkspace.location) { throw 'The existing VNet must be in the source workspace region.' }
        $networkParameters = @{
            existingVnetId = $vnet.id
            existingFunctionSubnetId = Get-ExistingSubnet $vnet $ExistingFunctionSubnetName $true
            existingPrivateEndpointSubnetId = Get-ExistingSubnet $vnet $ExistingPrivateEndpointSubnetName $false
        }
        if ($ExistingJumpHostSubnetName) { $existingJumpHostSubnetId = Get-ExistingSubnet $vnet $ExistingJumpHostSubnetName $false }
    }
    if ($ExistingEventHubNamespaceName) {
        $namespace = Invoke-AzJson @('eventhubs', 'namespace', 'show', '--subscription', $RouterSubscriptionId,
            '--resource-group', $RouterResourceGroup, '--name', $ExistingEventHubNamespaceName)
        if ($namespace.location -ne $sourceWorkspace.location) {
            throw 'The Event Hubs namespace must be in the source workspace region.'
        }
        if ($namespace.provisioningState -ne 'Succeeded' -or $namespace.sku.name -notin @('Standard', 'Premium') -or
            $namespace.disableLocalAuth -ne $false) {
            throw 'The existing namespace must be ready, Standard or Premium tier, and have local authorization enabled.'
        }
        if ($namespace.publicNetworkAccess -notin @('Enabled', 'Disabled')) {
            throw 'The existing namespace must not be managed by a network security perimeter.'
        }
        if ($namespace.publicNetworkAccess -eq 'Enabled') {
            Write-Warning 'This deployment disables public access and replaces firewall rules on the selected Event Hubs namespace. Use a dedicated namespace.'
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

    if ($createJumpHost -and -not $useJumpHostVault) {
        if ($null -eq $JumpHostAdminPassword) {
            $JumpHostAdminPassword = Read-Host "Windows password for $JumpHostAdminUsername" -AsSecureString
        }
        if ($null -eq $JumpHostAdminPassword -or $JumpHostAdminPassword.Length -eq 0) {
            throw 'The Windows jump-host password cannot be empty.'
        }
    }
    $null = Invoke-AzJson @('group', 'create', '--subscription', $RouterSubscriptionId,
        '--name', $RouterResourceGroup, '--location', $sourceWorkspace.location)
    $centralParameters = Write-Parameters 'central' (@{
        location = $sourceWorkspace.location; namePrefix = $NamePrefix
        eventHubName = $config.source.eventHubName; consumerGroup = $config.source.consumerGroup
        existingEventHubNamespaceName = $ExistingEventHubNamespaceName
        throughputUnits = $ThroughputUnits; routerEnabled = $false
    } + $networkParameters)
    $central = (Invoke-AzJson @('deployment', 'group', 'create', '--subscription', $RouterSubscriptionId,
        '--resource-group', $RouterResourceGroup, '--name', "$NamePrefix-central",
        '--template-file', (Join-Path (Join-Path $root 'infra') 'central.bicep'), '--parameters', "@$centralParameters")).properties.outputs
    if ($ExistingEventHubNamespaceName -and $namespace.publicNetworkAccess -ne 'Disabled') {
        $updatedNamespace = Invoke-AzJson @('eventhubs', 'namespace', 'update', '--subscription', $RouterSubscriptionId,
            '--resource-group', $RouterResourceGroup, '--name', $ExistingEventHubNamespaceName,
            '--public-network-access', 'Disabled')
        if ($updatedNamespace.publicNetworkAccess -ne 'Disabled') {
            throw 'Could not verify that public access is disabled on the reused Event Hubs namespace.'
        }
    }
    $scmHost = $central.functionScmHost.value
    if ($createJumpHost) {
        $routerVnet = ResourceParts $central.routerVnetId.value 'Microsoft.Network/virtualNetworks'
        $jumpParameters = @{
            location = @{ value = $sourceWorkspace.location }
            namePrefix = @{ value = $NamePrefix }
            routerVnetName = @{ value = $routerVnet.Name }
            existingJumpHostSubnetId = @{ value = $existingJumpHostSubnetId }
            jumpHostSubnetCidr = @{ value = $JumpHostSubnetCidr }
            rdpSourceIp = @{ value = $JumpHostRdpSourceIp }
        }
        if ($JumpHostAdminUsername) {
            $jumpParameters.adminUsername = @{ value = $JumpHostAdminUsername }
        }
        $jumpTemplate = Join-Path (Join-Path $root 'infra') 'jump-host.bicep'
        if ($useJumpHostVault) {
            $jumpParameters.adminPassword = @{ reference = @{
                keyVault = @{ id = $JumpHostPasswordVaultId }
                secretName = $JumpHostPasswordSecretName
            } }
            $parameterPath = Write-ParameterEntries 'jump-host' $jumpParameters
            $jump = (Invoke-AzJson @('deployment', 'group', 'create', '--subscription', $RouterSubscriptionId,
                '--resource-group', $RouterResourceGroup, '--name', "$NamePrefix-jump",
                '--template-file', $jumpTemplate, '--parameters', "@$parameterPath")).properties.outputs
        }
        else {
            $jump = Deploy-JumpHostWithPassword $jumpTemplate "$NamePrefix-jump" $jumpParameters
        }
        Write-Host "Windows jump host: $($jump.publicIpAddress.value) (RDP as $($jump.administrator.value) from $JumpHostRdpSourceIp)."
    }
    if ($InfrastructureOnly) {
        Write-Host "Private router infrastructure is ready. VNet: $($central.routerVnetId.value)"
        Write-Host "Connect the deployment machine to that network and configure private DNS for $scmHost. Then rerun without -InfrastructureOnly."
        return
    }

    try {
        $scm = Invoke-WebRequest -Method Get -Uri "https://$scmHost/api/deployments" -NoProxy `
            -TimeoutSec 20 -SkipHttpErrorCheck
    }
    catch {
        throw "Cannot reach private Function deployment endpoint $scmHost. Check private DNS, endpoint approval and VNet connectivity: $($_.Exception.Message)"
    }
    if ([int]$scm.StatusCode -notin @(200, 401)) {
        throw "Private Function deployment endpoint $scmHost returned HTTP $([int]$scm.StatusCode). Check private DNS, endpoint approval and VNet connectivity."
    }
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
            '--template-file', (Join-Path (Join-Path $root 'infra') 'destination.bicep'), '--parameters', "@$destinationParameters")).properties.outputs
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
        '--template-file', (Join-Path (Join-Path $root 'infra') 'export.bicep'), '--parameters', "@$exportParameters")
    Write-Host "Deployment finished. Generated configuration: $generatedConfig"
    Write-Host "Function: $($central.functionAppName.value). Quarantine account: $($central.storageAccountName.value)"
    Write-Host 'Verify trigger startup, RBAC propagation, export metrics, and destination row counts before production acceptance.'
}
finally { Pop-Location }
