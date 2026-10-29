#!/usr/bin/env bash
# Bring up the Kiirunavaara host, then stop for the human gate.
# With --after-manual-gate, install the app and run the checks.
# No account id, access key, password, token, or license is stored here.
set -euo pipefail

readonly TAG_KEY=kiirunavaara-demo
readonly TAG_VALUE=splunk-enterprise
readonly DEFAULT_NAME=kiruna-splunk-demo
readonly DEFAULT_REGION=eu-north-1

usage() {
  cat <<'EOF'
Run the Kiirunavaara demo host from a local AWS CLI.

This is the path the desktop Cursor agent uses. It does not generate a new
VPC, CDK app, or CloudFormation stack. It calls the scripts in this directory.

First run (no --after-manual-gate):
  Creates the host when it is missing, or starts it when it is stopped.
  Then it stops. Change the Marketplace admin password in Splunk Web, and
  have Emil install the unrestricted 50 GB/day NFR. Do not paste either
  value into chat or into these scripts.

Second run, after that person says the gate is done:
  bash scripts/aws/demo-pipeline.sh --after-manual-gate --app-bucket BUCKET

Required on the first run only when the instance does not exist yet:
  --admin-cidr CIDR

Required with --after-manual-gate:
  --app-bucket BUCKET

Optional: --profile, --region (eu-north-1 only), --name, --instance-id.
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
NAME=${SPLUNK_DEMO_NAME:-$DEFAULT_NAME}
INSTANCE_ID=${INSTANCE_ID:-}
ADMIN_CIDR=${ADMIN_CIDR:-}
APP_BUCKET=${APP_BUCKET:-}
AFTER_GATE=no

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
    --admin-cidr) [[ $# -ge 2 ]] || die "--admin-cidr needs a value"; ADMIN_CIDR=$2; shift 2 ;;
    --admin-cidr=*) ADMIN_CIDR=${1#*=}; shift ;;
    --app-bucket) [[ $# -ge 2 ]] || die "--app-bucket needs a value"; APP_BUCKET=$2; shift 2 ;;
    --app-bucket=*) APP_BUCKET=${1#*=}; shift ;;
    --after-manual-gate) AFTER_GATE=yes; shift ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || AWS_REGION=$DEFAULT_REGION
[[ "$AWS_REGION" == "$DEFAULT_REGION" ]] || die "This demo host is in ${DEFAULT_REGION}. Refusing region ${AWS_REGION}."
command -v aws >/dev/null 2>&1 || die "aws CLI is not on PATH. Run this from the desktop terminal where the CLI is already configured. Do not paste access keys."

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export AWS_DEFAULT_OUTPUT=json

aws_cli() {
  local -a aws_args
  aws_args=(aws --no-cli-pager)
  if [[ -n "$PROFILE" ]]; then
    aws_args+=(--profile "$PROFILE")
  fi
  aws_args+=(--region "$AWS_REGION")
  aws_args+=("$@")
  "${aws_args[@]}"
}

pass_common() {
  COMMON=()
  [[ -n "$PROFILE" ]] && COMMON+=(--profile "$PROFILE")
  COMMON+=(--region "$AWS_REGION" --name "$NAME")
  [[ -n "$INSTANCE_ID" ]] && COMMON+=(--instance-id "$INSTANCE_ID")
}

lookup_state() {
  local raw
  if [[ -n "$INSTANCE_ID" ]]; then
    raw=$(aws_cli ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --filters \
        "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text)
  else
    raw=$(aws_cli ec2 describe-instances \
      --filters \
        "Name=tag:Name,Values=${NAME}" \
        "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].State.Name' \
      --output text)
  fi
  if [[ "$raw" == "None" || "$raw" == "null" ]]; then
    raw=""
  fi
  printf '%s' "$raw"
}

state=$(lookup_state)
if [[ "$state" == *$'\n'* || "$state" == *$'\t'* || "$state" == *" "* ]]; then
  die "More than one demo instance is named ${NAME}. Pass --instance-id."
fi

pass_common
if [[ -z "$state" ]]; then
  [[ -n "$ADMIN_CIDR" ]] || die "No demo instance named ${NAME} in ${AWS_REGION}. Re-run with --admin-cidr."
  note "No demo instance yet. Creating it."
  bash "${HERE}/setup-splunk-enterprise.sh" "${COMMON[@]}" --admin-cidr "$ADMIN_CIDR"
elif [[ "$state" == running || "$state" == pending ]]; then
  note "Demo instance is ${state}."
  bash "${HERE}/demo-start.sh" "${COMMON[@]}"
else
  note "Demo instance is ${state}. Starting it."
  bash "${HERE}/demo-start.sh" "${COMMON[@]}"
fi

if [[ "$AFTER_GATE" != yes ]]; then
  cat <<'EOF'

Stopped before the app install. This is the manual gate:

1. Sign in to Splunk Web with the initial admin login from the Splunk Enterprise AMI usage instructions, then change that password.
2. Emil installs the unrestricted 50 GB/day NFR in Splunk Web, or with `splunk add licenses` after he copies the file onto the instance himself.

Do not paste the password, the license file, or AWS keys into chat. When both are done, run:

  bash scripts/aws/demo-pipeline.sh --after-manual-gate --app-bucket YOUR_BUCKET

Use an S3 bucket this AWS identity can already write. The script uploads the app tarball, installs it, deletes the object, and does not create the bucket.
EOF
  exit 0
fi

[[ -n "$APP_BUCKET" ]] || die "--after-manual-gate needs --app-bucket."
note "Manual gate acknowledged. Installing the app. This script still does not read a password or a license file."
set +e
bash "${HERE}/install-demo-app.sh" "${COMMON[@]}" --app-bucket "$APP_BUCKET"
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
  note "The app is on disk. Restart Splunk from Session Manager, then run scripts/aws/validate-demo.sh. No password was sent."
  exit 2
fi
[[ "$rc" -eq 0 ]] || exit "$rc"
bash "${HERE}/validate-demo.sh" "${COMMON[@]}"
