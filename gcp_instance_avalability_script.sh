#!/usr/bin/env bash

set -Euo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
randomizer=${RANDOM}
results_file="/tmp/${randomizer}_test_zones.log"

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -r us-east4 -i n2d-standard-2 -n 1 --role [dnode|cnode]

+-----------------------------------------------------------------------------------------------+
| This script is intended to test virtual machine creation in a specified region.              |
| It retrieves the list of zones within the region, creates the necessary resources in         |
| each zone, and performs cleanup by deleting the created resources.                           |
| Finally, it displays the success or failure results for each zone.                           |
|                                                                                              |
| Before running the script, ensure that the gcloud environment is preconfigured, including    |
| the default project, account, and required permissions!                                      |
+-----------------------------------------------------------------------------------------------+

Available options:

-h, --help           Print this help and exit
-i, --instance-type  Instance type to use (Example: c3d-standard-8) 
-n, --number_of_vms  Number of VMs to create
-r, --region         Google cloud region (Example: us-east4)
--role               Role to assign (must be 'dnode' or 'cnode')
--num_lssds          Number of lssds to attch in case of dnode role. (default 0)
-v, --verbose        Print script debug info
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2:-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  region=''
  instance_type=''
  role=''
  num_lssds=0 # Default to 0 if not provided

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -r | --region)
      region="${2-}"
      shift
      ;;
    -i | --instance-type)
      instance_type="${2-}"
      shift
      ;;
    -n | --number_of_vms)
      number_of_vms="${2-}"
      shift
      ;;
    --role)
      role="${2-}"
      shift
      ;;
    --num_lssds)
      num_lssds="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${region-}" ]] && die "Missing required parameter: region"
  [[ -z "${instance_type-}" ]] && die "Missing required parameter: --instance type"
  [[ -z "${number_of_vms-}" ]] && die "Missing required parameter: --number_of_vms"
  [[ -z "${role-}" ]] && die "Missing required parameter: --role"
  if [[ "${role}" != "dnode" && "${role}" != "cnode" ]]; then
    die "Invalid value for --role. Allowed values are 'dnode' or 'cnode'."
  fi

  return 0
}

validate_gcloud() {
  if ! command -v gcloud &> /dev/null; then
    die "gcloud is not installed. Please install gcloud to proceed."
  fi
}

print_table() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        echo "Error: File '$input_file' not found."
        return 1
    fi

    # Process and format the data
    awk -F', |: | ' '
    BEGIN {
        print "InstanceType\tZone\tCreatedVMs\tFailedVMs"
    }
    {
        instance_type = $2
        zone = $4
        created_vms = $7
        failed_vms = $12
        print instance_type "\t" zone "\t" created_vms "\t" failed_vms
    }
    ' "$input_file" | column -t
}

parse_params "$@"
validate_gcloud
rm -f ${results_file}

subnet_cidr="10.0.1.0/24"
network_name="test-net-${RANDOM}-${region}"

for ctype in $instance_type; do
    echo "Processing region: ${region}"
    subnet_name="test-sub-${randomizer}-${region}"
    sp_name="test-sp-${randomizer}-${region}"
    vm_name_pref="vm-${randomizer}-${region}"

    # Determine the CPU platform based on the instance type

    # Extract key characters from ctype for clarity
    ctype_prefix=${ctype:0:1}  # First character
    ctype_mid=${ctype:1:1}    # Second character
    ctype_suffix=${ctype:2:1} # Third character

    # Check for "d" in the third character (AMD-based platforms)
    if [[ $ctype_suffix == "d" ]]; then
        case $ctype_prefix in
            "n")
                cpu_platform="AMD Rome"
                ;;
            "c")
                case $ctype_mid in
                    "2")
                        cpu_platform="AMD Milan"
                        ;;
                    "3")
                        cpu_platform="AMD Genoa"
                        ;;
                    "4")
                        cpu_platform="Automatic"
                        ;;
                    *)
                        echo "Unknown instance type: $ctype ... Missing implementation!"
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "Unknown instance type: $ctype ... Missing implementation!"
                exit 1
                ;;
        esac

    # Otherwise, handle Intel-based platforms
    else
        case "${ctype_prefix}${ctype_mid}" in
            "c2")
                cpu_platform="Intel Cascade Lake"
                ;;
            "n2")
                cpu_platform="Intel Ice Lake"
                ;;
            "n4"|"c4")
                cpu_platform="Intel Emerald Rapids"
                ;;
            *)
                echo "Unknown instance type: $ctype ... Missing implementation!"
                exit 1
                ;;
        esac
    fi

echo "Selected CPU platform for $ctype: $cpu_platform"

  gcloud compute networks create "$network_name" --subnet-mode=custom
  gcloud compute networks subnets create "$subnet_name" --network "$network_name" --region "$region" --range "$subnet_cidr"
  gcloud compute resource-policies create group-placement $sp_name --availability-domain-count=8 --region="$region"

for zone in $(gcloud compute zones list --filter="region=$region" --format="value(name)"); do
    echo "Processing zone: $zone"
    unset success_count failure_count job_statuses
    success_count=0
    failure_count=0
    declare -A job_statuses
    for i in $(seq 1 "$number_of_vms"); do
        vm_name="${vm_name_pref}-${i}"   
        local_ssd_args=()
        for _ in $(seq 1 "$num_lssds"); do
            local_ssd_args+=("--local-ssd=interface=NVME")
        done   
        # Add local SSDs if the role is 'dnode'
        if [[ "$role" == "dnode" ]]; then
            gcloud compute instances create "$vm_name" \
                --zone "$zone" \
                --min-cpu-platform="$cpu_platform" \
                --machine-type "$ctype" \
                --resource-policies="$sp_name" \
                --network "$network_name" \
                --no-address \
                --subnet "$subnet_name" \
                "${local_ssd_args[@]}" \
                --quiet &
        else
            gcloud compute instances create "$vm_name" \
                --zone "$zone" \
                --min-cpu-platform="$cpu_platform" \
                --machine-type "$ctype" \
                --resource-policies="$sp_name" \
                --network "$network_name" \
                --no-address \
                --subnet "$subnet_name" \
                --quiet &
        fi
        
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
    
    echo "InstanceType: $ctype, Zone $zone: Successfully created $success_count VMs, failed to create $failure_count VMs" >> ${results_file}
    gcloud compute instances delete $(seq -f "${vm_name_pref}-%g" 1 $number_of_vms) --zone "$zone" --quiet
done

    gcloud compute networks subnets delete "$subnet_name" --region "$region" --quiet
    gcloud compute networks delete "$network_name" --quiet
    gcloud compute resource-policies delete "$sp_name" --region "$region"
    done
print_table ${results_file}
