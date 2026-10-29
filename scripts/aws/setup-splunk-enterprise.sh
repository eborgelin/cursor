#!/usr/bin/env bash
# One combined Splunk Enterprise host for the Kiirunavaara demo.
# Run from a local terminal with the AWS CLI. Region is eu-north-1.
# The instance boots a Splunk Enterprise 10.6.x image this account can already launch.
# This file has no account id, access key, password, token, AMI id, or license.
set -euo pipefail

readonly TAG_KEY=kiirunavaara-demo
readonly TAG_VALUE=splunk-enterprise
readonly DEFAULT_NAME=kiruna-splunk-demo
readonly DEFAULT_INSTANCE_TYPE=m6i.2xlarge
readonly DEFAULT_VOLUME_GB=300
readonly DEFAULT_REGION=eu-north-1

usage() {
  cat <<'EOF'
Create one Splunk Enterprise demo host (indexer and search head on the same instance).

Run this from a local terminal where the AWS CLI is installed and pointed at
the Splunk AWS account. The region is eu-north-1. Pass --profile or
AWS_PROFILE when the default CLI identity is not that account.

The instance boots the latest Splunk Enterprise 10.6.x x86_64 image this
account can already launch in eu-north-1 (owned, shared, or an existing
Marketplace subscription). The script does not subscribe to Marketplace,
does not download an RPM, and does not store an AMI id.

Required:
  --admin-cidr CIDR          VPN network allowed to reach Splunk Web (8000) and splunkd (8089)

Optional:
  --profile NAME             AWS CLI profile
  --region REGION            Must be eu-north-1. That is the default.
  --ami-id AMI               Use this image instead of the latest 10.6.x lookup.
                             It must be an x86_64 Splunk Enterprise 10.6.x image.
  --name NAME                Resource name (default kiruna-splunk-demo)
  --vpc-id ID                Use this VPC instead of creating one
  --subnet-id ID             Subnet in that VPC (required with --vpc-id).
                             A supplied subnet is reached over the VPN.
                             The instance does not get a public address.
  --availability-zone NAME   Used only when this script creates the subnet
  --instance-type TYPE       Default m6i.2xlarge
  --volume-size-gb N         Splunk volume in GiB (default 300). This is the
                             AMI root volume, because Splunk is already on the image.

Environment variables match the flags: AWS_PROFILE, AWS_REGION (or
AWS_DEFAULT_REGION), ADMIN_CIDR, SPLUNK_AMI_ID, SPLUNK_DEMO_NAME, VPC_ID,
SUBNET_ID, AVAILABILITY_ZONE, INSTANCE_TYPE, VOLUME_SIZE_GB.

The script does not prompt. It exits 0 when the instance exists or the image
is confirmed. It does not set the admin password or install the NFR license.
Those steps are printed at the end. No password is written here.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

PROFILE=${AWS_PROFILE:-}
AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$DEFAULT_REGION}}
ADMIN_CIDR=${ADMIN_CIDR:-}
AMI_ID=${SPLUNK_AMI_ID:-}
NAME=${SPLUNK_DEMO_NAME:-$DEFAULT_NAME}
VPC_ID=${VPC_ID:-}
SUBNET_ID=${SUBNET_ID:-}
AVAILABILITY_ZONE=${AVAILABILITY_ZONE:-}
INSTANCE_TYPE=${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}
VOLUME_SIZE_GB=${VOLUME_SIZE_GB:-$DEFAULT_VOLUME_GB}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile needs a value"
      PROFILE=$2
      shift 2
      ;;
    --profile=*)
      PROFILE=${1#*=}
      shift
      ;;
    --region)
      [[ $# -ge 2 ]] || die "--region needs a value"
      AWS_REGION=$2
      shift 2
      ;;
    --region=*)
      AWS_REGION=${1#*=}
      shift
      ;;
    --admin-cidr)
      [[ $# -ge 2 ]] || die "--admin-cidr needs a value"
      ADMIN_CIDR=$2
      shift 2
      ;;
    --admin-cidr=*)
      ADMIN_CIDR=${1#*=}
      shift
      ;;
    --ami-id)
      [[ $# -ge 2 ]] || die "--ami-id needs a value"
      AMI_ID=$2
      shift 2
      ;;
    --ami-id=*)
      AMI_ID=${1#*=}
      shift
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name needs a value"
      NAME=$2
      shift 2
      ;;
    --name=*)
      NAME=${1#*=}
      shift
      ;;
    --vpc-id)
      [[ $# -ge 2 ]] || die "--vpc-id needs a value"
      VPC_ID=$2
      shift 2
      ;;
    --vpc-id=*)
      VPC_ID=${1#*=}
      shift
      ;;
    --subnet-id)
      [[ $# -ge 2 ]] || die "--subnet-id needs a value"
      SUBNET_ID=$2
      shift 2
      ;;
    --subnet-id=*)
      SUBNET_ID=${1#*=}
      shift
      ;;
    --availability-zone)
      [[ $# -ge 2 ]] || die "--availability-zone needs a value"
      AVAILABILITY_ZONE=$2
      shift 2
      ;;
    --availability-zone=*)
      AVAILABILITY_ZONE=${1#*=}
      shift
      ;;
    --instance-type)
      [[ $# -ge 2 ]] || die "--instance-type needs a value"
      INSTANCE_TYPE=$2
      shift 2
      ;;
    --instance-type=*)
      INSTANCE_TYPE=${1#*=}
      shift
      ;;
    --volume-size-gb)
      [[ $# -ge 2 ]] || die "--volume-size-gb needs a value"
      VOLUME_SIZE_GB=$2
      shift 2
      ;;
    --volume-size-gb=*)
      VOLUME_SIZE_GB=${1#*=}
      shift
      ;;
    *)
      die "Unknown argument: $1 (see --help)"
      ;;
  esac
done

validate_args() {
  [[ -n "$AWS_REGION" ]] || AWS_REGION=$DEFAULT_REGION
  [[ "$AWS_REGION" == "$DEFAULT_REGION" ]] || die "This demo host is created in ${DEFAULT_REGION} from a local AWS CLI. Refusing region ${AWS_REGION}."
  [[ -n "$ADMIN_CIDR" ]] || die "ADMIN_CIDR is required. Pass --admin-cidr with the network that may open Splunk Web and splunkd."
  if [[ ! "$ADMIN_CIDR" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([1-9]|[1-2][0-9]|3[0-2])$ ]]; then
    die "ADMIN_CIDR must be an IPv4 CIDR such as 203.0.113.10/32. This script does not open 8000 or 8089 to 0.0.0.0/0."
  fi
  local o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]}
  if ((o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255)); then
    die "ADMIN_CIDR has an octet above 255: ${ADMIN_CIDR}"
  fi
  [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9-]{1,40}$ ]] || die "Name must start with a letter and use only letters, digits, and hyphens (41 characters max)."
  [[ -n "$INSTANCE_TYPE" ]] || die "Instance type is empty."
  [[ "$INSTANCE_TYPE" =~ ^[a-z0-9]+\.[a-z0-9]+$ ]] || die "Instance type must look like m6i.2xlarge."
  case "$INSTANCE_TYPE" in
    a1.*|t4g.*|m6g.*|m6gd.*|m7g.*|m7gd.*|m8g.*|c6g.*|c6gd.*|c6gn.*|c7g.*|c7gd.*|c7gn.*|c8g.*|r6g.*|r6gd.*|r7g.*|r7gd.*|r8g.*|x2gd.*|im4gn.*|is4gen.*|g5g.*|hpc7g.*)
      die "The Splunk Enterprise 10.6 image used here is x86_64. ${INSTANCE_TYPE} is a Graviton type. Use ${DEFAULT_INSTANCE_TYPE} or another x86-64 type."
      ;;
  esac
  [[ "$VOLUME_SIZE_GB" =~ ^[0-9]+$ ]] || die "VOLUME_SIZE_GB must be a whole number of GiB."
  if ((VOLUME_SIZE_GB < 50 || VOLUME_SIZE_GB > 16384)); then
    die "VOLUME_SIZE_GB must be between 50 and 16384."
  fi
  if ((VOLUME_SIZE_GB < DEFAULT_VOLUME_GB)); then
    note "warning: volume is ${VOLUME_SIZE_GB} GiB. The default ${DEFAULT_VOLUME_GB} GiB is the Splunk search-head dedicated-storage floor used for this demo."
  fi
  if [[ -n "$VPC_ID" && -z "$SUBNET_ID" ]]; then
    die "SUBNET_ID is required when VPC_ID is set. Pass a subnet the VPN can reach, or omit both and let the script create a VPC."
  fi
  if [[ -z "$VPC_ID" && -n "$SUBNET_ID" ]]; then
    die "Pass --vpc-id together with --subnet-id, or omit both."
  fi
  if [[ -n "$VPC_ID" && ! "$VPC_ID" =~ ^vpc-[0-9a-f]+$ ]]; then
    die "VPC_ID does not look like a VPC id."
  fi
  if [[ -n "$SUBNET_ID" && ! "$SUBNET_ID" =~ ^subnet-[0-9a-f]+$ ]]; then
    die "SUBNET_ID does not look like a subnet id."
  fi
  if [[ -n "$PROFILE" && "$PROFILE" == *[[:space:]]* ]]; then
    die "AWS profile name must not contain spaces."
  fi
  if [[ -n "$AMI_ID" && ! "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]]; then
    die "--ami-id must look like ami-0abc. Leave it unset to use the latest launchable Splunk Enterprise 10.6.x image."
  fi
}

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export AWS_DEFAULT_OUTPUT=json

aws_cli() {
  local -a cmd
  cmd=(aws --no-cli-pager)
  if [[ -n "$PROFILE" ]]; then
    cmd+=(--profile "$PROFILE")
  fi
  cmd+=(--region "$AWS_REGION")
  cmd+=("$@")
  "${cmd[@]}"
}

aws_text() {
  local result
  result="$(aws_cli "$@" --output text)"
  if [[ "$result" == "None" || "$result" == "null" ]]; then
    result=""
  fi
  printf '%s' "$result"
}

split_ids() {
  local raw=$1
  IDS=()
  if [[ -n "${raw//[[:space:]]/}" ]]; then
    # Intentional word split of AWS text output.
    # shellcheck disable=SC2206
    IDS=($raw)
  fi
}

tmp_dir=""
cleanup() {
  if [[ -n "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}

cli_suffix() {
  if [[ -n "$PROFILE" ]]; then
    printf ' --region %s --profile %s' "$AWS_REGION" "$PROFILE"
  else
    printf ' --region %s' "$AWS_REGION"
  fi
}

write_trust_json() {
  cat >"${tmp_dir}/trust.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

write_ssm_params() {
  cat >"${tmp_dir}/ssm-status.json" <<'EOF'
{"commands":["if [ -x /opt/splunk/bin/splunk ]; then echo image-ready; elif [ -f /var/lib/kiruna-splunk-setup/status ]; then head -n 1 /var/lib/kiruna-splunk-setup/status; else echo pending; fi"]}
EOF
}

# =============================================================================
# BEGIN INSTANCE_SOURCE
# Boot the latest Splunk Enterprise 10.6.x image this account can already
# launch in eu-north-1. A later Splunk Show image replaces this block only.
# Do not add a license file, an admin password, a download URL, or an AMI id.
# Leave the VPC, subnet, route, and security group sections outside this block.
# =============================================================================
write_user_data() {
  local dest=$1
  cat >"$dest" <<'END_USERDATA'
#!/bin/bash
set -euo pipefail
umask 022
mkdir -p /var/lib/kiruna-splunk-setup
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone Europe/Stockholm || true
fi
if [[ -x /opt/splunk/bin/splunk ]]; then
  printf 'image-ready\n' >/var/lib/kiruna-splunk-setup/status
else
  printf 'missing-splunk\n' >/var/lib/kiruna-splunk-setup/status
fi
exit 0
END_USERDATA
}

version_sort_key() {
  local ver=$1
  local IFS=.
  local -a p
  read -r -a p <<< "$ver"
  printf '%05d%05d%05d%05d' "${p[0]:-0}" "${p[1]:-0}" "${p[2]:-0}" "${p[3]:-0}"
}

splunk_106_version() {
  local blob=$1 lower
  lower=$(printf '%s' "$blob" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *forwarder*|*itsi*|*soar*|*phantom*|*add-on*|*addon*|*splunkcloud*)
      return 1
      ;;
  esac
  [[ "$lower" == *splunk* && "$lower" == *enterprise* ]] || return 1
  if [[ "$blob" =~ 10\.6\.[0-9]+(\.[0-9]+)? ]]; then
    printf '%s\n' "${BASH_REMATCH[0]}"
    return 0
  fi
  return 1
}

consider_image() {
  local id=$1 created=$2 name=$3 desc=$4
  local blob ver key
  [[ "$id" == ami-* ]] || return 0
  blob="${name} ${desc}"
  ver=$(splunk_106_version "$blob") || return 0
  key="$(version_sort_key "$ver")|${created}|${id}"
  if [[ -z "$BEST_KEY" || "$key" > "$BEST_KEY" ]]; then
    BEST_KEY=$key
    RESOLVED_AMI=$id
    RESOLVED_AMI_NAME=$name
    RESOLVED_AMI_VERSION=$ver
  fi
}

load_image_catalog() {
  aws_cli ec2 describe-images \
    --executable-users self \
    --filters \
      Name=state,Values=available \
      Name=architecture,Values=x86_64 \
      Name=image-type,Values=machine \
      Name=virtualization-type,Values=hvm \
      Name=root-device-type,Values=ebs \
    --query 'Images[].[ImageId,CreationDate,Name,Description]' \
    --output text
}

resolve_latest_ami() {
  local raw id created name desc
  BEST_KEY=""
  RESOLVED_AMI=""
  RESOLVED_AMI_NAME=""
  RESOLVED_AMI_VERSION=""
  raw=$(load_image_catalog)
  [[ -n "$raw" ]] || die "No x86_64 images are launchable in ${AWS_REGION} for this account. Subscribe to the Splunk Enterprise AMI in AWS Marketplace in ${AWS_REGION}, or share an existing 10.6.x image into this account. This script does not subscribe and does not download an RPM."
  while IFS=$'\t' read -r id created name desc; do
    [[ -n "$id" ]] || continue
    consider_image "$id" "$created" "$name" "$desc"
  done <<< "$raw"
  [[ -n "$RESOLVED_AMI" ]] || die "No launchable Splunk Enterprise 10.6.x x86_64 image was found in ${AWS_REGION}. The account needs an existing image whose name or description says Splunk Enterprise and 10.6.x. Universal Forwarder, ITSI, and Splunk Cloud images are skipped. This script does not subscribe to Marketplace."
  note "Splunk Enterprise image ${RESOLVED_AMI} ${RESOLVED_AMI_NAME} (${RESOLVED_AMI_VERSION})"
}

accept_explicit_ami() {
  local id=$1 name desc arch state blob ver
  name=$(aws_text ec2 describe-images --image-ids "$id" --query 'Images[0].Name')
  desc=$(aws_text ec2 describe-images --image-ids "$id" --query 'Images[0].Description')
  arch=$(aws_text ec2 describe-images --image-ids "$id" --query 'Images[0].Architecture')
  state=$(aws_text ec2 describe-images --image-ids "$id" --query 'Images[0].State')
  [[ -n "$name" ]] || die "AMI ${id} was not found in ${AWS_REGION}."
  [[ "$state" == available ]] || die "AMI ${id} is ${state}, not available."
  [[ "$arch" == x86_64 ]] || die "AMI ${id} is ${arch}. This demo uses the x86_64 Splunk Enterprise image."
  blob="${name} ${desc}"
  ver=$(splunk_106_version "$blob") || die "AMI ${id} (${name}) is not a Splunk Enterprise 10.6.x image."
  RESOLVED_AMI=$id
  RESOLVED_AMI_NAME=$name
  RESOLVED_AMI_VERSION=$ver
  note "Using requested Splunk Enterprise image ${RESOLVED_AMI} ${RESOLVED_AMI_NAME} (${RESOLVED_AMI_VERSION})"
}

read_root_device() {
  local id=$1 size
  ROOT_DEVICE_NAME=$(aws_text ec2 describe-images --image-ids "$id" --query 'Images[0].RootDeviceName')
  [[ -n "$ROOT_DEVICE_NAME" ]] || die "AMI ${id} has no root device name."
  size=$(aws_text ec2 describe-images --image-ids "$id" \
    --query "Images[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE_NAME}'].Ebs.VolumeSize | [0]")
  LAUNCH_VOLUME_GB=$VOLUME_SIZE_GB
  if [[ -n "$size" && "$size" =~ ^[0-9]+$ ]] && ((size > LAUNCH_VOLUME_GB)); then
    note "The image root snapshot is ${size} GiB, larger than ${VOLUME_SIZE_GB}. Launching at ${size} GiB."
    LAUNCH_VOLUME_GB=$size
  fi
}

launch_enterprise() {
  local role err rc attempt
  role="${NAME}-role"
  drop_installer_policy "$role"
  if [[ -n "$AMI_ID" ]]; then
    accept_explicit_ami "$AMI_ID"
  else
    resolve_latest_ami
  fi
  read_root_device "$RESOLVED_AMI"
  write_user_data "${tmp_dir}/user-data.sh"
  if [[ $(wc -c <"${tmp_dir}/user-data.sh") -gt 16000 ]]; then
    die "User-data is larger than 16 KB."
  fi
  cat >"${tmp_dir}/bdm.json" <<EOF
[
  {
    "DeviceName": "${ROOT_DEVICE_NAME}",
    "Ebs": {
      "VolumeSize": ${LAUNCH_VOLUME_GB},
      "VolumeType": "gp3",
      "Iops": 3000,
      "Throughput": 125,
      "Encrypted": true,
      "DeleteOnTermination": false
    }
  }
]
EOF
  if [[ "${USE_PUBLIC_IP:-}" == yes ]]; then
    ASSOCIATE_PUBLIC_IP=true
  else
    ASSOCIATE_PUBLIC_IP=false
  fi
  cat >"${tmp_dir}/nic.json" <<EOF
[
  {
    "DeviceIndex": 0,
    "SubnetId": "${SUBNET_ID}",
    "Groups": ["${SG_ID}"],
    "AssociatePublicIpAddress": ${ASSOCIATE_PUBLIC_IP},
    "DeleteOnTermination": true
  }
]
EOF
  err=$(mktemp)
  INSTANCE_ID=""
  for ((attempt = 1; attempt <= 12; attempt++)); do
    set +e
    INSTANCE_ID=$(aws_cli ec2 run-instances \
      --image-id "$RESOLVED_AMI" \
      --instance-type "$INSTANCE_TYPE" \
      --iam-instance-profile "Name=${NAME}-profile" \
      --network-interfaces "file://${tmp_dir}/nic.json" \
      --block-device-mappings "file://${tmp_dir}/bdm.json" \
      --user-data "file://${tmp_dir}/user-data.sh" \
      --metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2' \
      --instance-initiated-shutdown-behavior stop \
      --client-token "${NAME}-enterprise" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=kiruna-owned,Value=script},{Key=kiruna-splunk-image,Value=${RESOLVED_AMI_VERSION}}]" \
      --query 'Instances[0].InstanceId' \
      --output text 2>"$err")
    rc=$?
    set -e
    if ((rc == 0)) && [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
      break
    fi
    INSTANCE_ID=""
    if grep -Eqi 'instance profile|InvalidParameterValue|not yet propagated|does not exist' "$err" && ((attempt < 12)); then
      note "Waiting for the instance profile to become usable (${attempt}/12)."
      sleep 10
      continue
    fi
    if grep -Eqi 'OptInRequired|AuthFailure|not subscribed|Marketplace' "$err"; then
      cat "$err" >&2
      rm -f "$err"
      die "This account cannot launch ${RESOLVED_AMI} in ${AWS_REGION}. Use an image that is already subscribed or shared here."
    fi
    cat "$err" >&2
    rm -f "$err"
    exit 1
  done
  rm -f "$err"
  [[ -n "$INSTANCE_ID" ]] || die "RunInstances did not return an instance id."
  note "Instance ${INSTANCE_ID} is starting from ${RESOLVED_AMI} (${RESOLVED_AMI_VERSION})."
  aws_cli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  tag_instance_volumes "$INSTANCE_ID"
  note "Waiting until Systems Manager can see Splunk on the image."
  rc=0
  wait_for_package "$INSTANCE_ID" || rc=$?
  case "$rc" in
    0)
      note "Splunk Enterprise ${RESOLVED_AMI_VERSION} is on the instance. The image starts Splunk. The admin password is not set by this script."
      ;;
    2)
      note "Could not call ssm:SendCommand. The instance is up. Read /var/lib/kiruna-splunk-setup/status from a role that can use Systems Manager."
      ;;
    *)
      note "Splunk was not confirmed on the image. On the instance, read /var/lib/kiruna-splunk-setup/status."
      refresh_addresses "$INSTANCE_ID"
      print_summary
      print_manual_steps
      exit 1
      ;;
  esac
}
# =============================================================================
# END INSTANCE_SOURCE
# =============================================================================

wait_for_package() {
  local instance_id=$1
  local deadline=$((SECONDS + 1200))
  local err cmd inv_status out status attempt rc
  err=$(mktemp)
  while ((SECONDS < deadline)); do
    set +e
    cmd=$(aws_cli ssm send-command \
      --instance-ids "$instance_id" \
      --document-name AWS-RunShellScript \
      --comment "kiruna package status" \
      --parameters "file://${tmp_dir}/ssm-status.json" \
      --query 'Command.CommandId' \
      --output text 2>"$err")
    rc=$?
    set -e
    if ((rc != 0)); then
      if grep -E -q 'AccessDenied' "$err"; then
        rm -f "$err"
        return 2
      fi
      sleep 15
      continue
    fi
    inv_status=""
    for ((attempt = 1; attempt <= 30; attempt++)); do
      set +e
      inv_status=$(aws_cli ssm get-command-invocation \
        --command-id "$cmd" \
        --instance-id "$instance_id" \
        --query 'Status' \
        --output text 2>/dev/null)
      rc=$?
      set -e
      if ((rc == 0)) && [[ "$inv_status" == Success || "$inv_status" == Failed || "$inv_status" == Cancelled || "$inv_status" == TimedOut ]]; then
        break
      fi
      sleep 2
    done
    if [[ "$inv_status" != Success ]]; then
      sleep 10
      continue
    fi
    out=$(aws_cli ssm get-command-invocation \
      --command-id "$cmd" \
      --instance-id "$instance_id" \
      --query 'StandardOutputContent' \
      --output text)
    status=${out%%$'\n'*}
    status=${status//$'\r'/}
    case "$status" in
      image-ready|package-installed)
        rm -f "$err"
        return 0
        ;;
      missing-splunk|failed:*)
        printf '%s\n' "$status" >&2
        rm -f "$err"
        return 1
        ;;
    esac
    sleep 15
  done
  rm -f "$err"
  printf 'Timed out waiting for Splunk on the Enterprise image.\n' >&2
  return 1
}

read_package_status() {
  local instance_id=$1
  local err cmd inv_status out rc
  err=$(mktemp)
  set +e
  cmd=$(aws_cli ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "kiruna package status" \
    --parameters "file://${tmp_dir}/ssm-status.json" \
    --query 'Command.CommandId' \
    --output text 2>"$err")
  rc=$?
  set -e
  if ((rc != 0)); then
    rm -f "$err"
    printf 'unreadable'
    return 0
  fi
  rm -f "$err"
  inv_status=""
  local attempt
  for ((attempt = 1; attempt <= 20; attempt++)); do
    set +e
    inv_status=$(aws_cli ssm get-command-invocation \
      --command-id "$cmd" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null)
    rc=$?
    set -e
    if ((rc == 0)) && [[ "$inv_status" == Success || "$inv_status" == Failed ]]; then
      break
    fi
    sleep 2
  done
  if [[ "$inv_status" != Success ]]; then
    printf 'unreadable'
    return 0
  fi
  out=$(aws_cli ssm get-command-invocation \
    --command-id "$cmd" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' \
    --output text)
  out=${out%%$'\n'*}
  out=${out//$'\r'/}
  if [[ -z "$out" ]]; then
    printf 'unreadable'
  else
    printf '%s' "$out"
  fi
}

tag_instance_volumes() {
  local instance_id=$1
  local root_dev root_vol data_vol splunk_vol attempt
  DATA_VOLUME_ID=""
  for ((attempt = 1; attempt <= 12; attempt++)); do
    root_dev=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].RootDeviceName')
    root_vol=""
    data_vol=""
    if [[ -n "$root_dev" ]]; then
      root_vol=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${root_dev}'].Ebs.VolumeId | [0]")
    fi
    data_vol=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
      --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/sdf'].Ebs.VolumeId | [0]")
    if [[ -n "$root_vol" ]]; then
      if [[ -n "$data_vol" ]]; then
        aws_cli ec2 create-tags --resources "$root_vol" --tags \
          "Key=Name,Value=${NAME}-root" \
          "Key=${TAG_KEY},Value=${TAG_VALUE}" \
          "Key=kiruna-volume,Value=root" \
          "Key=kiruna-owned,Value=script"
        splunk_vol=$data_vol
      else
        splunk_vol=$root_vol
      fi
      aws_cli ec2 create-tags --resources "$splunk_vol" --tags \
        "Key=Name,Value=${NAME}-splunk-data" \
        "Key=${TAG_KEY},Value=${TAG_VALUE}" \
        "Key=kiruna-volume,Value=splunk-data" \
        "Key=kiruna-owned,Value=script"
      DATA_VOLUME_ID=$splunk_vol
      return 0
    fi
    sleep 5
  done
  note "warning: the Splunk volume id was not visible yet. Stop and teardown still must not assume it was deleted."
}

ensure_ingress() {
  local port=$1
  local desc=$2
  cat >"${tmp_dir}/ingress-${port}.json" <<EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": ${port},
    "ToPort": ${port},
    "IpRanges": [
      {"CidrIp": "${ADMIN_CIDR}", "Description": "${desc}"}
    ]
  }
]
EOF
  authorize_sg_permission authorize-security-group-ingress "${tmp_dir}/ingress-${port}.json"
}

ensure_egress() {
  local proto=$1
  local port=$2
  local desc=$3
  cat >"${tmp_dir}/egress-${proto}-${port}.json" <<EOF
[
  {
    "IpProtocol": "${proto}",
    "FromPort": ${port},
    "ToPort": ${port},
    "IpRanges": [
      {"CidrIp": "0.0.0.0/0", "Description": "${desc}"}
    ]
  }
]
EOF
  authorize_sg_permission authorize-security-group-egress "${tmp_dir}/egress-${proto}-${port}.json"
}

authorize_sg_permission() {
  local action=$1
  local file=$2
  local err rc
  err=$(mktemp)
  set +e
  aws_cli ec2 "$action" --group-id "$SG_ID" --ip-permissions "file://${file}" >/dev/null 2>"$err"
  rc=$?
  set -e
  if ((rc != 0)); then
    if grep -q 'InvalidPermission.Duplicate' "$err"; then
      rm -f "$err"
      return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
}

# Drop the default allow-all egress rule. Keep HTTPS (package, SSM, AWS APIs)
# and DNS. Do not open SSH or Splunk to 0.0.0.0/0.
restrict_egress() {
  local spec err rc
  cat >"${tmp_dir}/revoke-egress-v4.json" <<'EOF'
[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]
EOF
  cat >"${tmp_dir}/revoke-egress-v6.json" <<'EOF'
[{"IpProtocol":"-1","Ipv6Ranges":[{"CidrIpv6":"::/0"}]}]
EOF
  for spec in "${tmp_dir}/revoke-egress-v4.json" "${tmp_dir}/revoke-egress-v6.json"; do
    err=$(mktemp)
    set +e
    aws_cli ec2 revoke-security-group-egress \
      --group-id "$SG_ID" \
      --ip-permissions "file://${spec}" >/dev/null 2>"$err"
    rc=$?
    set -e
    if ((rc != 0)) && ! grep -q 'InvalidPermission.NotFound' "$err"; then
      cat "$err" >&2
      rm -f "$err"
      exit 1
    fi
    rm -f "$err"
  done
  ensure_egress tcp 443 "HttpsEgress"
  ensure_egress udp 53 "DnsEgress"
  ensure_egress tcp 53 "DnsTcpEgress"
}

ensure_security_group() {
  local raw
  raw=$(aws_text ec2 describe-security-groups \
    --filters "Name=group-name,Values=${NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[].GroupId')
  split_ids "$raw"
  if [[ ${#IDS[@]} -gt 1 ]]; then
    die "More than one security group named ${NAME} in ${VPC_ID}: ${IDS[*]}"
  fi
  if [[ ${#IDS[@]} -eq 1 ]]; then
    SG_ID=${IDS[0]}
  else
    SG_ID=$(aws_text ec2 create-security-group \
      --group-name "$NAME" \
      --description "Kiirunavaara demo Splunk Web 8000 and management 8089" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=kiruna-owned,Value=script}]" \
      --query 'GroupId')
  fi
  ensure_ingress 8000 "SplunkWeb"
  ensure_ingress 8089 "SplunkManagement"
  restrict_egress
}

require_public_subnet() {
  local subnet_id=$1 vpc_id=$2 rtb gw
  rtb=$(aws_text ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${subnet_id}" \
    --query 'RouteTables[0].RouteTableId')
  if [[ -z "$rtb" ]]; then
    rtb=$(aws_text ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${vpc_id}" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId')
  fi
  [[ -n "$rtb" ]] || die "Could not find a route table for subnet ${subnet_id}."
  gw=$(aws_text ec2 describe-route-tables --route-table-ids "$rtb" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]')
  if [[ "$gw" != igw-* ]]; then
    die "Subnet ${subnet_id} has no route to an internet gateway. The script-created network needs one. A VPN subnet is passed with --vpc-id and --subnet-id instead."
  fi
}

ensure_network() {
  local raw subnet_vpc az igw rtb existing_gw vpc_err vpc_rc
  OWNED_NETWORK=no
  if [[ -n "$VPC_ID" ]]; then
    raw=$(aws_text ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].VpcId')
    [[ -n "$raw" ]] || die "VPC ${VPC_ID} was not found in ${AWS_REGION}."
    subnet_vpc=$(aws_text ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId')
    [[ "$subnet_vpc" == "$VPC_ID" ]] || die "Subnet ${SUBNET_ID} is not in VPC ${VPC_ID}."
    USE_PUBLIC_IP=no
    note "Using subnet ${SUBNET_ID} in ${VPC_ID}. No public address. Reach Splunk from the VPN; --admin-cidr must be that VPN range."
    if [[ -n "$AVAILABILITY_ZONE" ]]; then
      note "Ignoring --availability-zone because --subnet-id was set."
    fi
    return 0
  fi

  raw=$(aws_text ec2 describe-vpcs \
    --filters \
      "Name=tag:Name,Values=${NAME}" \
      "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      "Name=tag:kiruna-owned,Values=script" \
    --query 'Vpcs[].VpcId')
  split_ids "$raw"
  if [[ ${#IDS[@]} -gt 1 ]]; then
    die "More than one demo VPC is named ${NAME}: ${IDS[*]}"
  fi
  if [[ ${#IDS[@]} -eq 1 ]]; then
    VPC_ID=${IDS[0]}
  else
    vpc_err=$(mktemp)
    set +e
    VPC_ID=$(aws_cli ec2 create-vpc \
      --cidr-block 10.42.0.0/16 \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=kiruna-owned,Value=script}]" \
      --query 'Vpc.VpcId' \
      --output text 2>"$vpc_err")
    vpc_rc=$?
    set -e
    if [[ "$VPC_ID" == "None" || "$VPC_ID" == "null" ]]; then
      VPC_ID=""
    fi
    if ((vpc_rc != 0)) || [[ -z "$VPC_ID" ]]; then
      cat "$vpc_err" >&2
      if grep -Eq 'UnauthorizedOperation|explicit deny|CreateVpc' "$vpc_err"; then
        rm -f "$vpc_err"
        die "This identity cannot create a VPC in ${AWS_REGION}. An organization service control policy is denying ec2:CreateVpc. Re-run with --vpc-id and --subnet-id of a subnet the VPN can already reach. The instance gets no public address. This script will not create a VPC, subnet, or internet gateway."
      fi
      rm -f "$vpc_err"
      die "VPC creation did not return a VPC id."
    fi
    rm -f "$vpc_err"
  fi
  OWNED_NETWORK=yes
  USE_PUBLIC_IP=yes
  [[ -n "$VPC_ID" ]] || die "VPC creation did not return a VPC id."
  # Shorthand, not a JSON blob. A JSON value here makes the AWS CLI drop vpc-id
  # and return MissingParameter vpcId.
  aws_cli ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support Value=true
  aws_cli ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames Value=true

  igw=$(aws_text ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId')
  if [[ -z "$igw" ]]; then
    igw=$(aws_text ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=kiruna-owned,Value=script}]" \
      --query 'InternetGateway.InternetGatewayId')
    aws_cli ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
  fi

  raw=$(aws_text ec2 describe-subnets \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME}-public" \
      "Name=tag:kiruna-owned,Values=script" \
    --query 'Subnets[].SubnetId')
  split_ids "$raw"
  if [[ ${#IDS[@]} -gt 1 ]]; then
    die "More than one demo subnet is named ${NAME}-public: ${IDS[*]}"
  fi
  if [[ ${#IDS[@]} -eq 1 ]]; then
    SUBNET_ID=${IDS[0]}
  else
    if [[ -z "$AVAILABILITY_ZONE" ]]; then
      az=$(aws_text ec2 describe-availability-zones \
        --filters "Name=state,Values=available" \
        --query 'AvailabilityZones[0].ZoneName')
      [[ -n "$az" ]] || die "No available availability zone in ${AWS_REGION}."
      AVAILABILITY_ZONE=$az
    fi
    SUBNET_ID=$(aws_text ec2 create-subnet \
      --vpc-id "$VPC_ID" \
      --cidr-block 10.42.1.0/24 \
      --availability-zone "$AVAILABILITY_ZONE" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-public},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=kiruna-owned,Value=script}]" \
      --query 'Subnet.SubnetId')
  fi
  [[ -n "$SUBNET_ID" ]] || die "Subnet creation did not return a subnet id."
  aws_cli ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch Value=true

  rtb=$(aws_text ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId')
  [[ -n "$rtb" ]] || die "Could not find the main route table for ${VPC_ID}."
  aws_cli ec2 create-tags --resources "$rtb" --tags \
    "Key=Name,Value=${NAME}-rtb" \
    "Key=${TAG_KEY},Value=${TAG_VALUE}" \
    "Key=kiruna-owned,Value=script"
  existing_gw=$(aws_text ec2 describe-route-tables --route-table-ids "$rtb" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]')
  if [[ -z "$existing_gw" ]]; then
    local route_err route_rc
    route_err=$(mktemp)
    set +e
    aws_cli ec2 create-route \
      --route-table-id "$rtb" \
      --destination-cidr-block 0.0.0.0/0 \
      --gateway-id "$igw" >/dev/null 2>"$route_err"
    route_rc=$?
    set -e
    if ((route_rc != 0)) && ! grep -q 'RouteAlreadyExists' "$route_err"; then
      cat "$route_err" >&2
      rm -f "$route_err"
      exit 1
    fi
    rm -f "$route_err"
  fi
}

drop_installer_policy() {
  local role=$1 err rc
  err=$(mktemp)
  set +e
  aws_cli iam delete-role-policy --role-name "$role" --policy-name splunk-installer-read >/dev/null 2>"$err"
  rc=$?
  set -e
  if ((rc != 0)) && ! grep -q 'NoSuchEntity' "$err"; then
    cat "$err" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
}

ensure_role() {
  local role="${NAME}-role"
  local profile="${NAME}-profile"
  local attached
  if ! aws_cli iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws_cli iam create-role \
      --role-name "$role" \
      --assume-role-policy-document "file://${tmp_dir}/trust.json" \
      --description "Kiirunavaara demo Splunk host. Session Manager only." \
      --tags "Key=Name,Value=${role}" "Key=${TAG_KEY},Value=${TAG_VALUE}"
  fi
  aws_cli iam attach-role-policy --role-name "$role" --policy-arn "$SSM_POLICY_ARN"
  drop_installer_policy "$role"
  if ! aws_cli iam get-instance-profile --instance-profile-name "$profile" >/dev/null 2>&1; then
    aws_cli iam create-instance-profile --instance-profile-name "$profile" \
      --tags "Key=Name,Value=${profile}" "Key=${TAG_KEY},Value=${TAG_VALUE}"
    aws_cli iam add-role-to-instance-profile --instance-profile-name "$profile" --role-name "$role"
  else
    attached=$(aws_cli iam get-instance-profile --instance-profile-name "$profile" \
      --query 'InstanceProfile.Roles[0].RoleName' --output text)
    if [[ "$attached" == "None" || -z "$attached" ]]; then
      aws_cli iam add-role-to-instance-profile --instance-profile-name "$profile" --role-name "$role"
    elif [[ "$attached" != "$role" ]]; then
      die "Instance profile ${profile} is attached to ${attached}, not ${role}."
    fi
  fi
}

find_existing_instance() {
  local raw
  EXISTING_INSTANCE_ID=""
  raw=$(aws_text ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=${NAME}" \
      "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId')
  split_ids "$raw"
  if [[ ${#IDS[@]} -gt 1 ]]; then
    die "More than one demo instance is named ${NAME}: ${IDS[*]}. Stop is safe. Tear one down before creating another."
  fi
  if [[ ${#IDS[@]} -eq 1 ]]; then
    EXISTING_INSTANCE_ID=${IDS[0]}
  fi
}

refresh_addresses() {
  local instance_id=$1
  PRIVATE_IP=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress')
  if [[ "${USE_PUBLIC_IP:-}" == yes ]]; then
    refresh_public_ip "$instance_id"
  else
    PUBLIC_IP=""
  fi
}

refresh_public_ip() {
  local instance_id=$1 attempt ip
  PUBLIC_IP=""
  for ((attempt = 1; attempt <= 10; attempt++)); do
    ip=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].PublicIpAddress')
    if [[ -n "$ip" ]]; then
      PUBLIC_IP=$ip
      return 0
    fi
    sleep 3
  done
}

load_instance_network() {
  local instance_id=$1
  VPC_ID=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].VpcId')
  SUBNET_ID=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].SubnetId')
  SG_ID=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].SecurityGroups[?GroupName=='${NAME}'].GroupId | [0]")
  if [[ -z "$SG_ID" ]]; then
    SG_ID=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId')
  fi
  local owned
  owned=$(aws_text ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].Tags[?Key==`kiruna-owned`].Value | [0]')
  if [[ "$owned" == "script" ]]; then
    OWNED_NETWORK=yes
  else
    OWNED_NETWORK=no
  fi
}

report_existing() {
  local instance_id=$1
  local state actual_type actual_size status rc
  INSTANCE_ID=$instance_id
  state=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].State.Name')
  actual_type=$(aws_text ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].InstanceType')
  note "Instance ${instance_id} already exists (${state}, ${actual_type}). Setup will not replace it."
  if [[ "$actual_type" != "$INSTANCE_TYPE" ]]; then
    note "warning: the instance type is ${actual_type}, not ${INSTANCE_TYPE}. Tear down and run setup again to change it."
  fi
  load_instance_network "$instance_id"
  if [[ -n "$SG_ID" ]]; then
    local group_name
    group_name=$(aws_text ec2 describe-security-groups --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].GroupName')
    ensure_ingress 8000 "SplunkWeb"
    ensure_ingress 8089 "SplunkManagement"
    if [[ "$group_name" == "$NAME" ]]; then
      restrict_egress
    fi
  fi
  tag_instance_volumes "$instance_id"
  if [[ -n "${DATA_VOLUME_ID:-}" ]]; then
    actual_size=$(aws_text ec2 describe-volumes --volume-ids "$DATA_VOLUME_ID" --query 'Volumes[0].Size')
    if [[ -n "$actual_size" && "$actual_size" != "$VOLUME_SIZE_GB" ]]; then
      note "warning: the data volume is ${actual_size} GiB, not ${VOLUME_SIZE_GB}. Tear down and run setup again to change it."
    fi
  fi
  if [[ "$OWNED_NETWORK" == yes ]]; then
    USE_PUBLIC_IP=yes
  else
    USE_PUBLIC_IP=no
  fi
  if [[ "$state" == running || "$state" == pending ]]; then
    refresh_addresses "$instance_id"
  else
    PUBLIC_IP=""
    PRIVATE_IP=""
  fi
  status=$(read_package_status "$instance_id")
  case "$status" in
    image-ready|package-installed)
      note "Splunk Enterprise is on the instance. This script does not set the admin password."
      rc=0
      ;;
    missing-splunk|failed:*)
      note "Splunk was not confirmed (${status}). Read /var/lib/kiruna-splunk-setup/status on the instance. Setup will not launch a second instance."
      rc=1
      ;;
    pending)
      note "Image status is still pending. Read /var/lib/kiruna-splunk-setup/status on the instance."
      rc=0
      ;;
    *)
      note "Image status was not read. Check /opt/splunk/bin/splunk on the instance."
      rc=0
      ;;
  esac
  print_summary
  print_manual_steps
  return "$rc"
}

print_summary() {
  local reach
  if [[ "${USE_PUBLIC_IP:-}" == yes ]]; then
    reach=public
  else
    reach=vpn
  fi
  cat <<EOF

Demo host
  name: ${NAME}
  region: ${AWS_REGION}
  instance_id: ${INSTANCE_ID}
  instance_type: ${INSTANCE_TYPE}
  private_ip: ${PRIVATE_IP:-none yet}
  public_ip: ${PUBLIC_IP:-none}
  reach: ${reach}
  vpc_id: ${VPC_ID:-unknown}
  subnet_id: ${SUBNET_ID:-unknown}
  security_group_id: ${SG_ID:-unknown}
  splunk_volume_id: ${DATA_VOLUME_ID:-unknown}
  splunk_volume_gib: ${LAUNCH_VOLUME_GB:-$VOLUME_SIZE_GB}
  owned_network: ${OWNED_NETWORK:-unknown}
  image_id: ${RESOLVED_AMI:-unknown}
  image_name: ${RESOLVED_AMI_NAME:-unknown}
  image_version: ${RESOLVED_AMI_VERSION:-unknown}
  splunk_home: /opt/splunk
EOF
}

print_manual_steps() {
  local suffix
  suffix=$(cli_suffix)
  cat <<EOF

Next steps are manual. This script does not fail because they are still pending,
except when the image does not contain Splunk.

1. Open Splunk Web. The Enterprise image already includes Splunk and starts it.
   From this same local AWS CLI:

   aws ssm start-session --target ${INSTANCE_ID}${suffix}

   Sign in with the initial admin login published in the AWS Marketplace usage
   instructions for the Splunk Enterprise AMI, then change that password.
   Do not copy the password into this script, user-data, or the repo.
   Record the build:

   sudo /opt/splunk/bin/splunk version

2. Emil installs the NFR license himself. It is unrestricted, 50 GB/day.
   In Splunk Web: Settings, Licensing, Add license.
   Or, on the instance, after he copies the file there himself:

   sudo /opt/splunk/bin/splunk add licenses /path/to/nfr.lic

   There is no license file in this repo. A missing license, trial expiry, or
   an unmeasured daily volume does not fail this setup.

The 50 GB/day figure is that NFR entitlement. It is not a measured ingest total.
Do not publish an unmeasured megabyte claim for the generator.

EOF
  if [[ "${USE_PUBLIC_IP:-}" == yes ]]; then
    cat <<EOF
Splunk Web, after the first start: http://${PUBLIC_IP:-PUBLIC_IP}:8000
Management: https://${PUBLIC_IP:-PUBLIC_IP}:8089
SSH is not open. The plan does not need it.
EOF
  else
    cat <<EOF
Open Splunk from the VPN, not from the public internet.
Splunk Web: http://${PRIVATE_IP:-PRIVATE_IP}:8000
Management: https://${PRIVATE_IP:-PRIVATE_IP}:8089
--admin-cidr is the VPN range allowed to reach those ports.
SSH is not open. The plan does not need it. This instance has no public address.
EOF
  fi
}

main() {
  validate_args
  command -v aws >/dev/null 2>&1 || die "aws CLI is not on PATH."
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiruna-aws.XXXXXX")
  trap cleanup EXIT
  write_trust_json
  write_ssm_params

  local arn account
  arn=$(aws_text sts get-caller-identity --query 'Arn')
  account=$(aws_text sts get-caller-identity --query 'Account')
  [[ -n "$arn" && -n "$account" ]] || die "aws sts get-caller-identity failed. Point the local AWS CLI at the Splunk AWS account."
  PARTITION=${arn#arn:}
  PARTITION=${PARTITION%%:*}
  SSM_POLICY_ARN="arn:${PARTITION}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  note "AWS identity (this must be a Splunk AWS account)"
  note "  account: ${account}"
  note "  arn: ${arn}"

  find_existing_instance
  if [[ -n "$EXISTING_INSTANCE_ID" ]]; then
    if report_existing "$EXISTING_INSTANCE_ID"; then
      return 0
    fi
    return 1
  fi

  ensure_network
  ensure_security_group
  ensure_role
  launch_enterprise
  refresh_addresses "$INSTANCE_ID"
  print_summary
  print_manual_steps
}

IDS=()
INSTANCE_ID=""
EXISTING_INSTANCE_ID=""
PUBLIC_IP=""
PRIVATE_IP=""
USE_PUBLIC_IP=""
ASSOCIATE_PUBLIC_IP=false
DATA_VOLUME_ID=""
SG_ID=""
OWNED_NETWORK=""
PARTITION=""
SSM_POLICY_ARN=""
RESOLVED_AMI=""
RESOLVED_AMI_NAME=""
RESOLVED_AMI_VERSION=""
ROOT_DEVICE_NAME=""
LAUNCH_VOLUME_GB=""
BEST_KEY=""

main "$@"
