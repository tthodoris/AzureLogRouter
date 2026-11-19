#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RouterSubscriptionId,
    [Parameter(Mandatory)][string] $RouterResourceGroup,
    [Parameter(Mandatory)][string] $FunctionAppName,
    [string] $ConfigurationPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\routing.deployed.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
    throw "Resolved routing configuration not found: $ConfigurationPath. Supply a config with the actual Event Hubs hostname and destination DCR immutable IDs and ingestion endpoints."
}
$config = (Resolve-Path -LiteralPath $ConfigurationPath).Path
$null = Get-Command az -ErrorAction Stop
$root = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $root 'artifacts'
$null = New-Item -Path $artifacts -ItemType Directory -Force
$id = [guid]::NewGuid().ToString('N')
$publish = Join-Path $artifacts "publish-$id"
$zip = Join-Path $artifacts "function-$id.zip"

Push-Location $root
try {
    $project = Join-Path $root 'src\LogRouter\LogRouter.csproj'
    & dotnet publish $project -c Release -o $publish
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

    & dotnet (Join-Path $publish 'LogRouter.dll') --validate-config $config
    if ($LASTEXITCODE -ne 0) { throw 'Routing configuration validation failed.' }

    Copy-Item -LiteralPath $config -Destination (Join-Path $publish 'routing.json') -Force
    [System.IO.Compression.ZipFile]::CreateFromDirectory($publish, $zip)
    Write-Host "Function package: $zip"

    & az functionapp deployment source config-zip --subscription $RouterSubscriptionId `
        --resource-group $RouterResourceGroup --name $FunctionAppName --src $zip `
        --build-remote false --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Function ZIP deployment failed. The package is available at $zip." }
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $publish -PathType Container) {
        Remove-Item -LiteralPath $publish -Recurse -Force
    }
}
