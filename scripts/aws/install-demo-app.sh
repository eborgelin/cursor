#!/usr/bin/env bash
# Install lkab_kiruna_demo onto the existing Kiirunavaara host.
# No account id, access key, password, token, or license is stored here.
set -euo pipefail

readonly TAG_KEY=kiirunavaara-demo
readonly TAG_VALUE=splunk-enterprise
readonly DEFAULT_NAME=kiruna-splunk-demo
readonly DEFAULT_REGION=eu-north-1
readonly DEFAULT_APP_BUCKET=kiruna-splunk-demo-app
readonly APP_ID=lkab_kiruna_demo

usage() {
  cat <<'EOF'
Package lkab_kiruna_demo from this checkout and install it on the demo host.

The host must already be running (setup-splunk-enterprise.sh, then demo-start.sh).
Splunk is already on the image. This does not set the admin password and does
not install the NFR license. Change the Marketplace password and add the NFR
before running this.

The app directory must be lkab_kiruna_demo/ in the same checkout. That tree is
on branch cursor/kiruna-app-v0.1. This script refuses a tree that contains a
license file, a certificate, or a credential-shaped string.

Optional:
  --app-bucket BUCKET        S3 bucket for the app tarball. Default, and the
                             APP_BUCKET value: kiruna-splunk-demo-app.
                             Create it with create-app-bucket.sh. The tarball
                             is uploaded, copied to the instance with a
                             15-minute presigned URL, then deleted. The URL is
                             not printed and is not written into the repo.
  --profile NAME             AWS CLI profile
  --region REGION            Must be eu-north-1. That is the default.
  --name NAME                Default kiruna-splunk-demo
  --instance-id ID           When more than one demo instance is named the same

The presigned URL is sent only in the Systems Manager command that downloads
the app tarball. Do not point this script at a license file.
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
APP_BUCKET=${APP_BUCKET:-$DEFAULT_APP_BUCKET}

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
    --app-bucket) [[ $# -ge 2 ]] || die "--app-bucket needs a value"; APP_BUCKET=$2; shift 2 ;;
    --app-bucket=*) APP_BUCKET=${1#*=}; shift ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || AWS_REGION=$DEFAULT_REGION
[[ "$AWS_REGION" == "$DEFAULT_REGION" ]] || die "This demo host is in ${DEFAULT_REGION}. Refusing region ${AWS_REGION}."
[[ -z "$INSTANCE_ID" || "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] || die "--instance-id must look like i-0abc."
[[ "$APP_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "--app-bucket must be an existing S3 bucket name."
[[ "$APP_BUCKET" != *..* ]] || die "--app-bucket must not contain '..'."
command -v aws >/dev/null 2>&1 || die "aws CLI is not on PATH."
command -v python3 >/dev/null 2>&1 || die "python3 is required to build the Systems Manager request."

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
    [[ -n "$raw" ]] || die "Instance ${INSTANCE_ID} is not a Kiirunavaara demo host in ${AWS_REGION}."
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

repo_root() {
  CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd
}

materialize_app() {
  local root=$1 dest=$2
  if [[ -f "${root}/${APP_ID}/app.manifest" ]]; then
    printf '%s' "${root}/${APP_ID}"
    return 0
  fi
  if git -C "$root" rev-parse --verify --quiet cursor/kiruna-app-v0.1 >/dev/null; then
    git -C "$root" archive cursor/kiruna-app-v0.1 "$APP_ID" | tar -x -C "$dest"
    [[ -f "${dest}/${APP_ID}/app.manifest" ]] || die "Branch cursor/kiruna-app-v0.1 has no ${APP_ID}/app.manifest."
    note "Using ${APP_ID} from branch cursor/kiruna-app-v0.1."
    printf '%s' "${dest}/${APP_ID}"
    return 0
  fi
  die "No ${APP_ID}/app.manifest in ${root}, and branch cursor/kiruna-app-v0.1 is not in this clone. Fetch that branch, or check out a tree that contains the app."
}

app_version() {
  local conf=$1 ver
  ver=$(awk '
    /^\[id\]/ { p = 1; next }
    /^\[/ { p = 0 }
    p && $0 ~ /^version[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$conf")
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not read a version from ${conf}."
  printf '%s' "$ver"
}

reject_package_secrets() {
  local root=$1 hit
  hit=$(find "$root" -type f \( -name '*.lic' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \) -print -quit)
  [[ -z "$hit" ]] || die "Refusing to package ${hit}. License files, certificates, and keys stay off this host path."
  hit=$(grep -R -l -E -I \
    'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|-----BEGIN (CERTIFICATE|PRIVATE KEY)|sk_live_|ghp_|AWSAccessKeyId|X-Amz-Signature' \
    "$root" || true)
  [[ -z "$hit" ]] || die "Refusing to package a file that looks like a credential or certificate: ${hit%%$'\n'*}"
}

wait_command() {
  local instance_id=$1 command_id=$2
  local deadline=$((SECONDS + 900)) inv_status rc
  while ((SECONDS < deadline)); do
    set +e
    inv_status=$(aws_cli ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null)
    rc=$?
    set -e
    if ((rc == 0)) && [[ "$inv_status" == Success || "$inv_status" == Failed || "$inv_status" == Cancelled || "$inv_status" == TimedOut ]]; then
      printf '%s' "$inv_status"
      return 0
    fi
    sleep 3
  done
  printf 'TimedOut'
}

ROOT=$(repo_root)
INSTANCE_ID=$(resolve_instance) || exit $?
state=$(aws_text ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name')
[[ "$state" == running ]] || die "Instance ${INSTANCE_ID} is ${state}. Run demo-start.sh and wait until it is running."

arn=$(aws_text sts get-caller-identity --query 'Arn')
[[ -n "$arn" ]] || die "aws sts get-caller-identity failed. Point the local AWS CLI at the Splunk AWS account."

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiruna-app.XXXXXX")
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

APP_DIR=$(materialize_app "$ROOT" "$tmp_dir")
reject_package_secrets "$APP_DIR"
VERSION=$(app_version "${APP_DIR}/default/app.conf")
note "Installing ${APP_ID} ${VERSION} on ${INSTANCE_ID}."

tarball="${tmp_dir}/${APP_ID}-${VERSION}.tgz"
tar -czf "$tarball" -C "$(dirname -- "$APP_DIR")" "$APP_ID"
python3 - "$tarball" <<'PY'
import sys, tarfile
path = sys.argv[1]
with tarfile.open(path, "r:gz") as tf:
    for member in tf.getmembers():
        name = member.name
        if name.startswith("/") or ".." in name.split("/"):
            sys.exit(f"unsafe tar member: {name}")
        if not (name == "lkab_kiruna_demo" or name.startswith("lkab_kiruna_demo/")):
            sys.exit(f"unexpected tar member: {name}")
        if name.endswith(".lic") or name.endswith(".pem") or name.endswith(".key"):
            sys.exit(f"refusing packaged secret-like file: {name}")
PY

key="kiruna-demo-app/${APP_ID}-${VERSION}.tgz"
aws_cli s3 cp "$tarball" "s3://${APP_BUCKET}/${key}" --only-show-errors
note "Uploaded s3://${APP_BUCKET}/${key}. A 15-minute download URL is sent to Systems Manager and is not printed."

presign=$(aws_cli s3 presign "s3://${APP_BUCKET}/${key}" --expires-in 900)
case "$presign" in
  https://*) ;;
  *) die "Could not presign the app object." ;;
esac
case "$presign" in
  *$'\n'*|*$'\r'*) die "Refusing a download URL that contains a newline." ;;
esac

python3 - "$presign" "$tmp_dir/ssm.json" <<'PY'
import json, sys
url, dest = sys.argv[1], sys.argv[2]
remote = r"""set -eu
umask 077
install -d -m 0700 /var/lib/kiruna-splunk-setup
pkg=/var/lib/kiruna-splunk-setup/lkab_kiruna_demo.tgz
members=/var/lib/kiruna-splunk-setup/lkab_kiruna_demo.members
if ! curl -fsS -o "$pkg" -- __URL__ >/dev/null; then
  printf 'download-failed\n'
  rm -f "$pkg"
  exit 1
fi
tar -tzf "$pkg" > "$members"
while IFS= read -r name; do
  case "$name" in
    lkab_kiruna_demo|lkab_kiruna_demo/*) ;;
    *) printf 'unexpected-tar-member\n'; rm -f "$pkg" "$members"; exit 1 ;;
  esac
  case "$name" in
    *../*|*/../*|../*|*/..) printf 'unsafe-tar-member\n'; rm -f "$pkg" "$members"; exit 1 ;;
    *.lic|*.pem|*.key) printf 'refusing-secret-like-member\n'; rm -f "$pkg" "$members"; exit 1 ;;
  esac
done < "$members"
rm -f "$members"
rm -rf /opt/splunk/etc/apps/lkab_kiruna_demo
tar -xzf "$pkg" -C /opt/splunk/etc/apps
rm -f "$pkg"
if id splunk >/dev/null 2>&1; then
  chown -R splunk:splunk /opt/splunk/etc/apps/lkab_kiruna_demo
fi
if [ ! -f /opt/splunk/etc/apps/lkab_kiruna_demo/default/app.conf ]; then
  printf 'install-missing-app\n'
  exit 1
fi
if systemctl cat Splunkd.service >/dev/null 2>&1; then
  systemctl restart Splunkd
elif systemctl cat splunk.service >/dev/null 2>&1; then
  systemctl restart splunk
else
  printf 'installed-restart-manual\n'
  exit 2
fi
printf 'installed\n'
"""
remote = remote.replace("__URL__", json.dumps(url))
with open(dest, "w", encoding="utf-8") as fh:
    json.dump({"commands": [remote]}, fh)
PY

# The parameters file holds the download URL. Keep it out of the log.
command_id=$(aws_cli ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "kiruna install lkab_kiruna_demo" \
  --parameters "file://${tmp_dir}/ssm.json" \
  --query 'Command.CommandId' \
  --output text)
rm -f "${tmp_dir}/ssm.json"
[[ -n "$command_id" && "$command_id" != None ]] || die "Systems Manager did not accept the install command."
note "Systems Manager command ${command_id} is installing the app."

inv=$(wait_command "$INSTANCE_ID" "$command_id")
out=$(aws_cli ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' \
  --output text 2>/dev/null || true)
err=$(aws_cli ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$INSTANCE_ID" \
  --query 'StandardErrorContent' \
  --output text 2>/dev/null || true)
# Drop anything that still looks like the download URL before printing.
sanitize() {
  printf '%s\n' "$1" | sed -E 's#https://[^[:space:]]+#<download-url-redacted>#g'
}

if [[ "$inv" != Success ]]; then
  note "Install command finished ${inv}."
  sanitize "$out" >&2
  sanitize "$err" >&2
  note "The object s3://${APP_BUCKET}/${key} is still in the bucket. Delete it if you stop here."
  if printf '%s' "$out" | grep -q 'installed-restart-manual'; then
    note "The app directory is on the instance. Restart Splunk from Session Manager. Do not put the admin password in the restart command."
    exit 2
  fi
  exit 1
fi

aws_cli s3 rm "s3://${APP_BUCKET}/${key}" --only-show-errors || note "Could not delete s3://${APP_BUCKET}/${key}. Remove that app object yourself."
note "Installed ${APP_ID} ${VERSION} on ${INSTANCE_ID}. No admin password was sent."
note "Open the app in Splunk Web, save setup, and enable the generator. Then run scripts/aws/validate-demo.sh."
