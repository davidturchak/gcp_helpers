#!/usr/bin/env bash

set -Euo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -r eastus -s Standard_D2s_v3 -n 1

+-----------------------------------------------------------------------------------------------+
| This script is intended to test virtual machine creation in a specified region.              |
| It retrieves the list of zones within the region, creates the necessary resources in         |
| each zone, and performs cleanup by deleting the created resources.                           |
| Finally, it displays the success or failure results for each zone.                           |
|                                                                                              |
| Before running the script, ensure that the Azure CLI environment is preconfigured, including |
| the default subscription, account, and required permissions!                                 |
+-----------------------------------------------------------------------------------------------+

Available options:

-h, --help      Print this help and exit
-s, --size      VM size to use (Example: Standard_D2s_v3)
-n, --number    Number of VMs to create
-r, --region    Azure region (Example: eastus)
-v, --verbose   Print script debug info
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2:-1}
  msg "$msg"
  exit "$code"
}

parse_params() {
  region=''
  size=''
  number_of_vms=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -r | --region)
      region="${2-}"
      shift
      ;;
    -s | --size)
      size="${2-}"
      shift
      ;;
    -n | --number)
      number_of_vms="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${region-}" ]] && die "Missing required parameter: region"
  [[ -z "${size-}" ]] && die "Missing required parameter: size"
  [[ -z "${number_of_vms-}" ]] && die "Missing required parameter: number"

  return 0
}

print_table() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        echo "Error: File '$input_file' not found."
        return 1
    fi

    awk -F',|:
    BEGIN {
        print "VMSize\tZone\tCreatedVMs\tFailedVMs"
    }
    {
        size = $0
        zone = $1
        created_vms = $7
        failed_vms = $12
        print vm_size "\t" zone "\t" created_vms "\t" failed_vms
    }
    ' "$input_file" | column -t
}

create_resource_group() {
  local resource_group=$1
  local region=$2
  az group create --name "$resource_group" --location "$region" --output tsv
}

create_vnet() {
  local vnet_name=$1
  local resource_group=$2
  local subnet_name=$3
  az network vnet create \
    --name "$vnet_name" \
    --resource-group "$resource_group" \
    --address-prefixes "10.0.0.0/16" \
    --subnet-name "$subnet_name" \
    --subnet-prefix "10.0.1.0/24" \
    --output tsv
}

create_vm() {
  local vm_name=$1
  local resource_group=$2
  local region=$3
  local size=$4
  local vnet_name=$5
  local subnet_name=$6
  local zone=$7
  az vm create \
    --resource-group "$resource_group" \
    --name "$vm_name" \
    --location "$region" \
    --size "$size" \
    --image "CentOS85Gen2" \
    --vnet-name "$vnet_name" \
    --subnet "$subnet_name" \
    --zone "$zone" \
    --public-ip-address "" \
    --no-wait \
    --output tsv
}

main() {
  parse_params "$@"
  setup_colors

  resource_group="test-rg-${region}"
  vnet_name="test-vnet-${region}"
  subnet_name="test-subnet-${region}"

  create_resource_group "$resource_group" "$region"
  create_vnet "$vnet_name" "$resource_group" "$subnet_name"
  
 
  readarray -t zones < <(az vm list-skus --location "$region" --size "$size" --output json | jq -r '.[0].locationInfo[0].zones[]')

  rm -f /tmp/test_zones.log
  for zone in "${zones[@]}"; do
  success_count=0
  failure_count=0
  declare -A job_statuses

  for i in $(seq 1 "$number_of_vms"); do
    vm_name="vm-${region}z${zone}-${i}"
    create_vm "$vm_name" "$resource_group" "$region" "$size" "$vnet_name" "$subnet_name" "$zone" &
    job_statuses[$!]="$vm_name"
  done

  # Wait for all background jobs to complete
  for job in "${!job_statuses[@]}"; do
      if wait "$job"; then
          success_count=$((success_count + 1))
      else
          failure_count=$((failure_count + 1))
      fi
  done

  echo "VMSize: $size, Zone: $zone Successfully created: $success_count, Failed to create: $failure_count" >> /tmp/test_zones.log
done

  az group delete --name "$resource_group" --yes --no-wait --output tsv
  print_table "/tmp/test_zones.log"
}

main "$@"
