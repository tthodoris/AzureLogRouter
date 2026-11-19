#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-linux.sh \
    --configuration PATH \
    --resource-group NAME \
    --name-prefix PREFIX \
    [--subscription-id ID] \
    [--existing-eventhub-namespace NAME] \
    [--infrastructure-only] \
    [--function-access Private|Public] \
    [--existing-vnet-id ID --existing-function-subnet-name NAME --existing-private-endpoint-subnet-name NAME] \
    [--existing-jump-host-subnet-name NAME] \
    [--vnet-cidr CIDR --function-subnet-cidr CIDR --private-endpoint-subnet-cidr CIDR --jump-host-subnet-cidr CIDR] \
    [--jump-host-rdp-source-ip IP --jump-host-admin-username USER] \
    [--jump-host-password-vault-id ID --jump-host-password-secret-name NAME] \
    [--throughput-units COUNT] \
    [--nuget-source URL]

Run from the project directory so relative configuration paths resolve there.
EOF
}

args=()
infrastructure_only=false
while (($#)); do
  case "$1" in
    --configuration)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-ConfigurationPath' "$2")
      shift 2
      ;;
    --resource-group)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-RouterResourceGroup' "$2")
      shift 2
      ;;
    --name-prefix)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-NamePrefix' "$2")
      shift 2
      ;;
    --subscription-id)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-RouterSubscriptionId' "$2")
      shift 2
      ;;
    --existing-eventhub-namespace)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-ExistingEventHubNamespaceName' "$2")
      shift 2
      ;;
    --infrastructure-only)
      infrastructure_only=true
      shift
      ;;
    --function-access)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-FunctionAccess' "$2")
      shift 2
      ;;
    --existing-vnet-id|--existing-function-subnet-name|--existing-private-endpoint-subnet-name|--existing-jump-host-subnet-name|--vnet-cidr|--function-subnet-cidr|--private-endpoint-subnet-cidr|--jump-host-subnet-cidr)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --existing-vnet-id) parameter='-ExistingVnetId' ;;
        --existing-function-subnet-name) parameter='-ExistingFunctionSubnetName' ;;
        --existing-private-endpoint-subnet-name) parameter='-ExistingPrivateEndpointSubnetName' ;;
        --existing-jump-host-subnet-name) parameter='-ExistingJumpHostSubnetName' ;;
        --vnet-cidr) parameter='-VnetCidr' ;;
        --function-subnet-cidr) parameter='-FunctionSubnetCidr' ;;
        --private-endpoint-subnet-cidr) parameter='-PrivateEndpointSubnetCidr' ;;
        --jump-host-subnet-cidr) parameter='-JumpHostSubnetCidr' ;;
      esac
      args+=("$parameter" "$2")
      shift 2
      ;;
    --jump-host-rdp-source-ip)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-JumpHostRdpSourceIp' "$2")
      shift 2
      ;;
    --jump-host-admin-username)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-JumpHostAdminUsername' "$2")
      shift 2
      ;;
    --jump-host-password-vault-id)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-JumpHostPasswordVaultId' "$2")
      shift 2
      ;;
    --jump-host-password-secret-name)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-JumpHostPasswordSecretName' "$2")
      shift 2
      ;;
    --throughput-units)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-ThroughputUnits' "$2")
      shift 2
      ;;
    --nuget-source)
      (($# >= 2)) || { usage >&2; exit 2; }
      args+=('-NuGetSource' "$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for required in -ConfigurationPath -RouterResourceGroup -NamePrefix; do
  found=false
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    if [[ "${args[i]}" == "$required" ]]; then
      found=true
      break
    fi
  done
  [[ "$found" == true ]] || { usage >&2; exit 2; }
done

if [[ "$infrastructure_only" == true ]]; then
  args+=('-InfrastructureOnly')
fi

bash "$script_dir/check-linux-prerequisites.sh"
cd "$repo_root"
exec pwsh -NoLogo -NoProfile -File "$script_dir/Deploy.ps1" "${args[@]}"
