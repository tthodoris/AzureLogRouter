#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for command in pwsh dotnet az; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command '$command' was not found. Install PowerShell 7, .NET 10 SDK, and Azure CLI."
done

pwsh_version=$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major' | tr -d '\r')
[[ "$pwsh_version" =~ ^[0-9]+$ ]] || fail "Could not determine PowerShell version."
(( pwsh_version >= 7 )) || fail "PowerShell 7 or later is required; found version $pwsh_version."

dotnet_version=$(dotnet --version)
dotnet_major=${dotnet_version%%.*}
[[ "$dotnet_major" =~ ^[0-9]+$ ]] || fail "Could not determine .NET SDK version."
(( dotnet_major >= 10 )) || fail ".NET 10 SDK or later is required; found $dotnet_version."

az bicep version >/dev/null || fail "Azure CLI Bicep is unavailable. Install it with: az bicep install"
az account show --only-show-errors --output none ||
  fail "Azure CLI is not logged in. Run 'az login' and select an identity with deployment permissions."

printf 'Linux deployment prerequisites are available.\n'
printf 'PowerShell: %s\n.NET SDK: %s\nAzure CLI: %s\n' \
  "$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" \
  "$dotnet_version" \
  "$(az version --query '"azure-cli"' --output tsv)"
