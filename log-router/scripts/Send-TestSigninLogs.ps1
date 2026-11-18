[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [Parameter(Mandatory)][string] $ResourceGroup,
    [string] $DcrName = 'dcr-synthetic-signins'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
$json = & az resource show --ids $id --api-version 2023-03-11 --only-show-errors --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to retrieve the synthetic test DCR.' }
$dcr = ($json -join "`n") | ConvertFrom-Json
$endpoint = $dcr.properties.endpoints.logsIngestion
if (-not $endpoint -or -not $dcr.properties.immutableId) { throw 'Test DCR has no direct ingestion endpoint or immutable ID.' }

$token = & az account get-access-token --subscription $SubscriptionId `
    --resource 'https://monitor.azure.com/' --query accessToken --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Unable to obtain a Logs Ingestion API token.' }
$account = & az account show --subscription $SubscriptionId --query tenantId --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $account) { throw 'Unable to resolve the subscription tenant.' }

$time = [DateTime]::UtcNow.ToString('o')
$records = @(
    @{ TimeGenerated = $time; AADTenantId = $account; UserPrincipalName = 'ttsironis@example.invalid'; Message = 'Synthetic test: law1' }
    @{ TimeGenerated = $time; AADTenantId = $account; UserPrincipalName = 'gdouka@example.invalid'; Message = 'Synthetic test: law2' }
    @{ TimeGenerated = $time; AADTenantId = $account; UserPrincipalName = 'unmatched@example.invalid'; Message = 'Synthetic test: should be filtered' }
)
$uri = "$($endpoint.TrimEnd('/'))/dataCollectionRules/$($dcr.properties.immutableId)/streams/Custom-SyntheticSigninLogs_CL?api-version=2023-01-01"
Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $records -Depth 5) | Out-Null
Write-Host 'Sent three synthetic records. Allow time for ingestion and query SyntheticSigninLogs_CL.'
