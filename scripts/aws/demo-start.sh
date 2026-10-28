#!/usr/bin/env bash
# Start the Kiirunavaara demo Splunk Enterprise instance.
# No account id, access key, password, token, or license is stored here.
set -euo pipefail

readonly TAG_KEY=kiirunavaara-demo
readonly TAG_VALUE=splunk-enterprise
readonly DEFAULT_NAME=kiruna-splunk-demo
readonly DEFAULT_REGION=eu-north-1

usage() {
  cat <<'EOF'
Start the demo Splunk Enterprise EC2 instance.

If it is already running, this prints that and exits 0.
Stopping and starting again can change the public IP. EBS volumes stay attached.
There is no NAT gateway to start. SSH is not used.

Region defaults to eu-north-1, which is where the demo host is created.
Pass --region only as eu-north-1. Run this from a local terminal with the AWS CLI.
Optional: --profile / AWS_PROFILE, --name / SPLUNK_DEMO_NAME (default kiruna-splunk-demo),
--instance-id / INSTANCE_ID.

The instance must already exist. Create it with setup-splunk-enterprise.sh.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

PROFILE=${AWS_PROFILE:-}
AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$DEFAULT_REGION}}
NAME=${SPLUNK_DEMO_NAME:-$DEFAULT_NAME}
INSTANCE_ID=${INSTANCE_ID:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --profile) [[ $# -ge 2 ]] || die "--profile needs a value"; PROFILE=$2; shift 2 ;;
    --profile=*) PROFILE=${1#*=}; shift ;;
    --region) [[ $# -ge 2 ]] || die "--region needs a value"; AWS_REGION=$2; shift 2 ;;
    --region=*) AWS_REGION=${1#*=}; shift ;;
    --name) [[ $# -ge 2 ]] || die "--name needs a value"; NAME=$2; shift 2 ;;
    --name=*) NAME=${1#*=}; shift ;;
    --instance-id) [[ $# -ge 2 ]] || die "--instance-id needs a value"; INSTANCE_ID=$2; shift 2 ;;
    --instance-id=*) INSTANCE_ID=${1#*=}; shift ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || AWS_REGION=$DEFAULT_REGION
[[ "$AWS_REGION" == "$DEFAULT_REGION" ]] || die "This demo host is in ${DEFAULT_REGION}. Refusing region ${AWS_REGION}."
[[ -z "$INSTANCE_ID" || "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] || die "--instance-id must look like i-0abc."
command -v aws >/dev/null 2>&1 || die "aws CLI is not on PATH."

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

resolve_instance() {
  local raw
  if [[ -n "$INSTANCE_ID" ]]; then
    raw=$(aws_text ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --filters \
        "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId')
    [[ -n "$raw" ]] || die "Instance ${INSTANCE_ID} is not a running-or-stopped Kiirunavaara demo host in ${AWS_REGION}."
    printf '%s' "$raw"
    return 0
  fi
  raw=$(aws_text ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=${NAME}" \
      "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId')
  local -a ids=()
  if [[ -n "${raw//[[:space:]]/}" ]]; then
    # shellcheck disable=SC2206
    ids=($raw)
  fi
  if [[ ${#ids[@]} -eq 0 ]]; then
    die "No demo instance named ${NAME} in ${AWS_REGION}. Run setup-splunk-enterprise.sh first."
  fi
  if [[ ${#ids[@]} -gt 1 ]]; then
    die "More than one demo instance is named ${NAME}: ${ids[*]}. Pass --instance-id."
  fi
  printf '%s' "${ids[0]}"
}

print_endpoint() {
  local id=$1 attempt ip
  ip=""
  for ((attempt = 1; attempt <= 10; attempt++)); do
    ip=$(aws_text ec2 describe-instances --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].PublicIpAddress')
    [[ -n "$ip" ]] && break
    sleep 3
  done
  if [[ -n "$ip" ]]; then
    printf 'Public IP: %s\n' "$ip"
    printf 'Splunk Web, once Splunk is started: http://%s:8000\n' "$ip"
    printf 'Management: https://%s:8089\n' "$ip"
  else
    printf 'No public IP yet. Describe the instance in a moment:\n' 
    printf 'aws ec2 describe-instances --instance-ids %s --region %s --query Reservations[0].Instances[0].PublicIpAddress --output text\n' "$id" "$AWS_REGION"
  fi
  printf 'The address can change after a stop.\n'
  printf 'If boot-start was enabled, Splunk starts with the instance. If not, the host is up and Splunk stays stopped until the first start.\n'
  printf 'No NAT gateway or other dependent resource is started. EBS volumes stay attached.\n'
}

INSTANCE_ID=$(resolve_instance) || exit $?
state=$(aws_text ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name')

case "$state" in
  running)
    printf 'Instance %s is already running.\n' "$INSTANCE_ID"
    print_endpoint "$INSTANCE_ID"
    exit 0
    ;;
  pending)
    printf 'Instance %s is already starting. Waiting until it is running.\n' "$INSTANCE_ID"
    aws_cli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    print_endpoint "$INSTANCE_ID"
    exit 0
    ;;
  stopping)
    printf 'Instance %s is stopping. Waiting, then starting it.\n' "$INSTANCE_ID"
    aws_cli ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    aws_cli ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_cli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    printf 'Instance %s is running.\n' "$INSTANCE_ID"
    print_endpoint "$INSTANCE_ID"
    exit 0
    ;;
  stopped)
    printf 'Starting instance %s.\n' "$INSTANCE_ID"
    aws_cli ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_cli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    printf 'Instance %s is running.\n' "$INSTANCE_ID"
    print_endpoint "$INSTANCE_ID"
    exit 0
    ;;
  *)
    die "Instance ${INSTANCE_ID} is ${state}. This command only starts a stopped demo instance."
    ;;
esac
