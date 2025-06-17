#!/usr/bin/env bash

set -Euo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
randomizer=${RANDOM}
results_file="/tmp/${randomizer}_test_zones.log"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -r eastus -s Standard_D2s_v3 -n 1 [--zone 1] [--dnodes | --cnodes]

+-----------------------------------------------------------------------------------------------+
| This script is intended to test virtual machine creation in a specified region.              |
| It retrieves the list of zones within the region, creates the necessary resources in         |
| each zone, and performs cleanup by deleting the created resources.                           |
| Finally, it displays the success or failure results for each zone.                           |
|                                                                                              |
| Before running the script, ensure that the Azure CLI environment is preconfigured, including |
| the default subscription, account, JQ installed and required permissions!                    |
+-----------------------------------------------------------------------------------------------+

Available options:

-h, --help      Print this help and exit
-s, --size      VM size to use (Example: Standard_D2s_v3)
-n, --number    Number of VMs to create
-r, --region    Azure region (Example: eastus)
--zone          Use a specific zone instead of querying (Example: 1)
--dnodes        Create groups of 16 VMs (mutually exclusive with --cnodes)
--cnodes        Create groups of 8 VMs (mutually exclusive with --dnodes)
-v, --verbose   Print script debug info
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
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
  msg "${RED}$msg${NOFORMAT}"
  exit "$code"
}

validate_jq() {
  if ! command -v jq &> /dev/null; then
    die "jq is not installed. Please install jq to proceed."
  fi
}

validate_az() {
  if ! command -v az &> /dev/null; then
    die "az-cli is not installed. Please install az-cli to proceed."
  fi
}

parse_params() {
  region=''
  size=''
  number_of_vms=''
  zone=''
  dnodes=false
  cnodes=false

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
    --zone)
      zone="${2-}"
      shift
      ;;
    --dnodes) dnodes=true ;;
    --cnodes) cnodes=true ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${region-}" ]] && die "Missing required parameter: region"
  [[ -z "${size-}" ]] && die "Missing required parameter: size"
  [[ -z "${number_of_vms-}" ]] && die "Missing required parameter: number"

  # Validate number_of_vms is a positive integer
  if ! [[ "$number_of_vms" =~ ^[0-9]+$ ]] || [ "$number_of_vms" -le 0 ]; then
    die "Number of VMs must be a positive integer"
  fi

  # Validate dnodes and cnodes
  if [[ "$dnodes" == true && "$cnodes" == true ]]; then
    die "Cannot specify both --dnodes and --cnodes"
  elif [[ "$dnodes" == false && "$cnodes" == false ]]; then
    die "Must specify either --dnodes or --cnodes"
  fi

  return 0
}

print_table() {
  local input_file="$1"

  if [[ ! -f "$input_file" ]]; then
    echo "Error: File '$input_file' not found."
    return 1
  fi

  awk -v region="$region" '
  BEGIN {
    print "VMSize\t\tZone\t\tGroup\t\tCreatedVMs\tFailedVMs"
  }
  {
    gsub(",", "", $0)
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^VMSize:/) vm_size = $(i+1)
      if ($i ~ /^Zone:/) zone = $(i+1)
      if ($i ~ /^Group:/) group = $(i+1)
      if ($i ~ /^Successfully/) created_vms = $(i+2)
      if ($i ~ /^Failed/) failed_vms = $(i+3)
    }
    print vm_size "\t" region "-" zone "\t" group "\t" created_vms "\t" failed_vms
  }' "$input_file" | column -t
}

create_resource_group() {
  local resource_group=$1
  local region=$2
  msg "Creating resource group '$resource_group' in region '$region'..."
  if ! az group create --name "$resource_group" --location "$region" --output none; then
    die "Failed to create resource group '$resource_group'"
  fi
}

create_vnet() {
  local vnet_name=$1
  local resource_group=$2
  local subnet_name=$3
  msg "Creating virtual network '$vnet_name' in resource group '$resource_group'..."
  if ! az network vnet create \
    --name "$vnet_name" \
    --resource-group "$resource_group" \
    --address-prefixes "10.0.0.0/16" \
    --subnet-name "$subnet_name" \
    --subnet-prefix "10.0.1.0/24" \
    --output none; then
    die "Failed to create virtual network '$vnet_name'"
  fi
}

create_proximity_placement_group() {
  local ppg_name=$1
  local resource_group=$2
  local region=$3
  local zone=$4
  msg "Creating Proximity Placement Group '$ppg_name' in region '$region', zone '$zone'..."
  if ! az ppg create \
    --name "$ppg_name" \
    --resource-group "$resource_group" \
    --location "$region" \
    --type "Standard" \
    --zone "$zone" \
    --intent-vm-sizes "$size" \
    --output none; then
    die "Failed to create Proximity Placement Group '$ppg_name'"
  fi
}

create_availability_set() {
  local as_name=$1
  local resource_group=$2
  local region=$3
  local ppg_name=$4
  msg "Creating Availability Set '$as_name' in region '$region'..."
  if ! az vm availability-set create \
    --name "$as_name" \
    --resource-group "$resource_group" \
    --location "$region" \
    --ppg "$ppg_name" \
    --platform-fault-domain-count 3 \
    --platform-update-domain-count 20 \
    --output none; then
    die "Failed to create Availability Set '$as_name'"
  fi
}

# Initialize colors early to avoid unbound variable errors
setup_colors

main() {
  validate_jq
  validate_az
  parse_params "$@"

  resource_group="test${RANDOM}-rg-${region}"
  vnet_name="test-vnet-${region}"
  subnet_name="test-subnet-${region}"

  msg "Creating resource group and virtual network..."
  create_resource_group "$resource_group" "$region"
  create_vnet "$vnet_name" "$resource_group" "$subnet_name"

  if [[ -n "${zone}" ]]; then
    msg "Using user-specified zone: $zone"
    zones=("$zone")
  else
    msg "Fetching available zones for region '$region' and VM size '$size'... (may be slow)"
    if ! zones_json=$(az vm list-skus --location "$region" --size "$size" --output json); then
      die "Failed to fetch available zones for region '$region' and VM size '$size'"
    fi
    readarray -t zones < <(echo "$zones_json" | jq -r '.[0].locationInfo[0].zones[]')
  fi

  # Set group size based on dnodes or cnodes
  if [[ "$dnodes" == true ]]; then
    group_size=16
  else
    group_size=8
  fi

  # Calculate number of groups
  num_groups=$(( (number_of_vms + group_size - 1) / group_size ))

  declare -A ppg_map
  declare -A as_map

  # Create PPG and AS for each group in each zone
  for zone in "${zones[@]}"; do
    for group in $(seq 1 "$num_groups"); do
      ppg_name="ppg-${region}-z${zone}-g${group}-${RANDOM}"
      as_name="as-${region}-z${zone}-g${group}-${RANDOM}"
      create_proximity_placement_group "$ppg_name" "$resource_group" "$region" "$zone"
      create_availability_set "$as_name" "$resource_group" "$region" "$ppg_name"
      ppg_map["$zone,$group"]="$ppg_name"
      as_map["$zone,$group"]="$as_name"
    done
  done

  rm -f "${results_file}"
  for zone in "${zones[@]}"; do
    for group in $(seq 1 "$num_groups"); do
      unset success_count failure_count job_statuses
      success_count=0
      failure_count=0
      declare -A job_statuses

      ppg_name="${ppg_map[$zone,$group]}"
      as_name="${as_map[$zone,$group]}"

      # Calculate VMs for this group
      start_vm=$(( (group - 1) * group_size + 1 ))
      end_vm=$(( group * group_size ))
      if [ $end_vm -gt $number_of_vms ]; then
        end_vm=$number_of_vms
      fi

      msg "Starting VM creation in zone '$zone', group '$group' using PPG '$ppg_name'..."
      for i in $(seq "$start_vm" "$end_vm"); do
        vm_name="vm-${region}-z${zone}-g${group}-${i}"
        az vm create \
          --resource-group "$resource_group" \
          --name "$vm_name" \
          --location "$region" \
          --size "$size" \
          --image "Debian:debian-12:12-gen2:latest" \
          --vnet-name "$vnet_name" \
          --subnet "$subnet_name" \
          --security-type TrustedLaunch \
          --enable-secure-boot false \
          --admin-username silkus \
          --ppg "$ppg_name" \
          --public-ip-address "" \
          --accelerated-networking \
          --availability-set "$as_name" \
          --enable-secure-boot false \
          --only-show-errors \
          --output none &
        job_statuses[$!]="$vm_name"
      done

      sleep 5
      msg "Waiting for all VMs to be created in zone '$zone', group '$group'..."
      for job in "${!job_statuses[@]}"; do
        if wait "$job"; then
          success_count=$((success_count + 1))
        else
          failure_count=$((failure_count + 1))
        fi
      done

      msg "Finished VM creation in zone '$zone', group '$group'. Success: $success_count, Failure: $failure_count."
      echo "VMSize: $size, Zone: $zone, Group: $group, Successfully created: $success_count, Failed to create: $failure_count" >> "${results_file}"
    done
  done

  msg "Cleaning up by deleting resource group '$resource_group'..."
  if ! az group delete --name "$resource_group" --yes --no-wait --output none; then
    die "Failed to delete resource group '$resource_group'"
  fi
  print_table "${results_file}"
}

main "$@"
