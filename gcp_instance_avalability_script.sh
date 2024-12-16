#!/usr/bin/env bash

set -Euo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

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

-h, --help      Print this help and exit
-i, --instance-type  Instance type to use (Example: c3d-standard-8) 
-n, --number_of_vms   Number of VMs to create
-r, --region    Google cloud region (Example: us-east4)
--role          Role to assign (must be 'dnode' or 'cnode')
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
  local code=${2:-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  region=''
  instance_type=''
  role=''

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
setup_colors
validate_gcloud
rm -f /tmp/test_zones.log

subnet_cidr="10.0.1.0/24"
network_name="test-net-${region}"

for ctype in $instance_type; do
    echo "Processing region: $region"
    subnet_name="test-sub-$region"
    sp_name="test-sp-$region"

    if [[ ${ctype:2:1} == "d" ]]; then
       if [[ ${ctype:0:1} == "n" ]]; then 
	      cpu_platform="AMD Rome"
       elif [[ ${ctype:0:1} == "c" ]]; then
         if [[ ${ctype:1:1} == "2" ]] then
          cpu_platform="AMD Milan"
         else
	        cpu_platform="AMD Genoa"
        fi
       else 
	echo "Unknown instance type - need to implement a cpu_platform"
	exit 1
       fi
    else
       cpu_platform="Intel Ice Lake"
    fi
  gcloud compute networks create "$network_name" --subnet-mode=custom
  gcloud compute networks subnets create "$subnet_name" --network "$network_name" --region "$region" --range "$subnet_cidr"
  gcloud compute resource-policies create group-placement $sp_name --availability-domain-count=8 --region="$region"

for zone in $(gcloud compute zones list --filter="region:($region)" --format="value(name)"); do
    echo "Processing zone: $zone"
    unset success_count failure_count job_statuses
    success_count=0
    failure_count=0
    declare -A job_statuses
    for i in $(seq 1 "$number_of_vms"); do
        vm_name="vm-${zone}-${i}"      
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
                --local-ssd=interface=NVME \
                --local-ssd=interface=NVME \
                --local-ssd=interface=NVME \
                --local-ssd=interface=NVME \
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
    
    echo "InstanceType: $ctype, Zone $zone: Successfully created $success_count VMs, failed to create $failure_count VMs" >> /tmp/test_zones.log
    gcloud compute instances delete $(seq -f "vm-${zone}-%g" 1 $number_of_vms) --zone "$zone" --quiet
done

    gcloud compute networks subnets delete "$subnet_name" --region "$region" --quiet
    gcloud compute networks delete $network_name --quiet
    gcloud compute resource-policies delete "$sp_name" --region "$region"
    done
print_table "/tmp/test_zones.log"
