#!/usr/bin/env bash
# Check the Kiirunavaara app package and, when the host is up, the installed copy.
# No account id, access key, password, token, or license is stored here.
set -euo pipefail

readonly TAG_KEY=kiirunavaara-demo
readonly TAG_VALUE=splunk-enterprise
readonly DEFAULT_NAME=kiruna-splunk-demo
readonly DEFAULT_REGION=eu-north-1
readonly APP_ID=lkab_kiruna_demo

usage() {
  cat <<'EOF'
Validate the Kiirunavaara demo package and the copy on the demo host.

Local checks read lkab_kiruna_demo/ in this checkout, or the tree on branch
cursor/kiruna-app-v0.1 when that branch is already fetched. They do not log
in to Splunk.

Remote checks use Systems Manager on the running demo instance. They read
splunk version, confirm the app directory, and confirm the kiruna_events
index stanza. They do not use an admin password, so they cannot save setup,
enable the generator, or judge Shift Brief.

Optional:
  --profile NAME
  --region REGION            Must be eu-north-1. That is the default.
  --name NAME                Default kiruna-splunk-demo
  --instance-id ID
  --local-only               Skip the instance
  --require-appinspect       Fail if the splunk-appinspect command is absent

Without --local-only, a missing instance is an error. AppInspect runs only
when its command is on PATH, unless --require-appinspect is set.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

fail_check() {
  printf 'fail: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

ok_check() {
  printf 'ok: %s\n' "$*"
}

PROFILE=${AWS_PROFILE:-}
AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$DEFAULT_REGION}}
NAME=${SPLUNK_DEMO_NAME:-$DEFAULT_NAME}
INSTANCE_ID=${INSTANCE_ID:-}
LOCAL_ONLY=no
REQUIRE_APPINSPECT=no
FAILURES=0

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
    --local-only) LOCAL_ONLY=yes; shift ;;
    --require-appinspect) REQUIRE_APPINSPECT=yes; shift ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || AWS_REGION=$DEFAULT_REGION
[[ "$AWS_REGION" == "$DEFAULT_REGION" ]] || die "This demo host is in ${DEFAULT_REGION}. Refusing region ${AWS_REGION}."
[[ -z "$INSTANCE_ID" || "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] || die "--instance-id must look like i-0abc."

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

repo_root() {
  CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd
}

conf_value() {
  local file=$1 stanza=$2 key=$3
  awk -v stanza="$stanza" -v key="$key" '
    $0 ~ "^\\[" stanza "\\]" { p = 1; next }
    /^\[/ { p = 0 }
    p && $0 ~ "^" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$file"
}

check_local() {
  local app=$1 manifest version id_version launcher_version
  [[ -f "${app}/app.manifest" ]] || { fail_check "missing app.manifest"; return; }
  [[ -f "${app}/default/app.conf" ]] || { fail_check "missing default/app.conf"; return; }
  manifest=$(grep -E '"name"[[:space:]]*:[[:space:]]*"lkab_kiruna_demo"' "${app}/app.manifest" || true)
  [[ -n "$manifest" ]] || fail_check "app.manifest name is not lkab_kiruna_demo"
  version=$(python3 - "$app/app.manifest" <<'PY' || true
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["info"]["id"]["version"])
PY
)
  id_version=$(conf_value "${app}/default/app.conf" id version)
  launcher_version=$(conf_value "${app}/default/app.conf" launcher version)
  [[ "$version" == "$id_version" && "$version" == "$launcher_version" && -n "$version" ]] \
    || fail_check "app.manifest, [id], and [launcher] versions differ (${version:-missing} / ${id_version:-missing} / ${launcher_version:-missing})"
  [[ "$(conf_value "${app}/default/app.conf" install is_configured)" == "0" ]] \
    || fail_check "[install] is_configured is not 0"
  [[ "$(conf_value "${app}/default/app.conf" ui setup_view)" == "setup_page_dashboard" ]] \
    || fail_check "setup_view is not setup_page_dashboard"
  [[ "$(conf_value "${app}/default/app.conf" package id)" == "$APP_ID" ]] \
    || fail_check "[package] id is not ${APP_ID}"
  [[ ! -f "${app}/default/setup.xml" ]] || fail_check "default/setup.xml must not ship"
  [[ ! -f "${app}/default/lkab_kiruna_demo_settings.conf" ]] \
    || fail_check "default settings conf must not ship; setup writes local/"
  grep -q '^\[kiruna_events\]' "${app}/default/indexes.conf" \
    || fail_check "indexes.conf has no [kiruna_events]"
  grep -q 'frozenTimePeriodInSecs[[:space:]]*=[[:space:]]*1814400' "${app}/default/indexes.conf" \
    || fail_check "kiruna_events retention is not frozenTimePeriodInSecs = 1814400"
  grep -q '^disabled[[:space:]]*=[[:space:]]*1' "${app}/default/inputs.conf" \
    || fail_check "modular input is not disabled in the package"
  grep -q '^index[[:space:]]*=[[:space:]]*kiruna_events' "${app}/default/inputs.conf" \
    || fail_check "modular input index is not kiruna_events"
  if find "$app" -type f \( -name '*.lic' -o -name '*.pem' -o -name '*.key' \) | grep -q .; then
    fail_check "package contains a license, certificate, or key file"
  fi
  if [[ "$FAILURES" -eq 0 ]]; then
    ok_check "package ${APP_ID} ${version} matches the v0.1 packaging checks"
  fi
}

check_appinspect() {
  local app=$1
  if ! command -v splunk-appinspect >/dev/null 2>&1; then
    if [[ "$REQUIRE_APPINSPECT" == yes ]]; then
      fail_check "splunk-appinspect is not on PATH"
    else
      note "appinspect: skipped (splunk-appinspect is not on PATH). Zero failures remains the packaging exit when you run it."
    fi
    return
  fi
  local mode
  for mode in test precert; do
    if splunk-appinspect inspect "$app" --mode "$mode"; then
      ok_check "AppInspect --mode ${mode} completed"
    else
      fail_check "AppInspect --mode ${mode} exited non-zero"
    fi
  done
}

resolve_instance() {
  local raw
  if [[ -n "$INSTANCE_ID" ]]; then
    raw=$(aws_text ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --filters \
        "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].InstanceId')
    [[ -n "$raw" ]] || die "Instance ${INSTANCE_ID} is not a running Kiirunavaara demo host in ${AWS_REGION}."
    printf '%s' "$raw"
    return 0
  fi
  raw=$(aws_text ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=${NAME}" \
      "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId')
  local -a ids=()
  if [[ -n "${raw//[[:space:]]/}" ]]; then
    # shellcheck disable=SC2206
    ids=($raw)
  fi
  if [[ ${#ids[@]} -eq 0 ]]; then
    die "No running demo instance named ${NAME} in ${AWS_REGION}."
  fi
  if [[ ${#ids[@]} -gt 1 ]]; then
    die "More than one running demo instance is named ${NAME}: ${ids[*]}. Pass --instance-id."
  fi
  printf '%s' "${ids[0]}"
}

wait_command() {
  local instance_id=$1 command_id=$2
  local deadline=$((SECONDS + 300)) inv_status rc
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

check_remote() {
  local instance_id=$1 tmp command_id inv out
  command -v python3 >/dev/null 2>&1 || die "python3 is required to build the Systems Manager request."
  tmp=$(mktemp)
  python3 - "$tmp" <<'PY'
import json, sys
remote = r"""set -eu
if [ ! -x /opt/splunk/bin/splunk ]; then
  printf 'missing-splunk\n'
  exit 1
fi
/opt/splunk/bin/splunk version
if [ ! -f /opt/splunk/etc/apps/lkab_kiruna_demo/default/app.conf ]; then
  printf 'missing-app\n'
  exit 1
fi
if [ -f /opt/splunk/etc/apps/lkab_kiruna_demo/default/setup.xml ]; then
  printf 'unexpected-setup-xml\n'
  exit 1
fi
btool=$(/opt/splunk/bin/splunk btool indexes list kiruna_events 2>/dev/null || true)
printf '%s\n' "$btool"
case "$btool" in
  *'[kiruna_events]'*) printf 'index-ok\n' ;;
  *) printf 'index-missing\n'; exit 1 ;;
esac
printf 'remote-ok\n'
"""
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"commands": [remote]}, fh)
PY
  command_id=$(aws_cli ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "kiruna validate demo app" \
    --parameters "file://${tmp}" \
    --query 'Command.CommandId' \
    --output text)
  rm -f "$tmp"
  [[ -n "$command_id" && "$command_id" != None ]] || die "Systems Manager did not accept the validation command."
  inv=$(wait_command "$instance_id" "$command_id")
  out=$(aws_cli ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || true)
  printf '%s\n' "$out"
  if [[ "$inv" != Success ]] || ! printf '%s\n' "$out" | grep -q 'remote-ok'; then
    fail_check "remote check on ${instance_id} finished ${inv}"
    return
  fi
  ok_check "remote package is on ${instance_id} and kiruna_events is defined"
}

print_manual() {
  cat <<'EOF'

Still a person, in Splunk Web. These scripts do not log in and do not read a password.

- Save setup. A backfill of 15 days is rejected. Saving sets is_configured and opens Shift Brief.
- Enable the generator on healthy-shift with 14 backfill days.
- Shift Brief shows a heartbeat and illustrative KPIs.
- Record `splunk version` in the app README. It stays "needs review" until that string is copied.
- AppInspect --mode test and --mode precert, when the CLI is installed. Zero failures is the packaging exit.
EOF
}

ROOT=$(repo_root)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiruna-validate.XXXXXX")
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

if [[ -f "${ROOT}/${APP_ID}/app.manifest" ]]; then
  APP_DIR="${ROOT}/${APP_ID}"
elif git -C "$ROOT" rev-parse --verify --quiet cursor/kiruna-app-v0.1 >/dev/null; then
  git -C "$ROOT" archive cursor/kiruna-app-v0.1 "$APP_ID" | tar -x -C "$tmp_dir"
  APP_DIR="${tmp_dir}/${APP_ID}"
  note "Local checks use ${APP_ID} from branch cursor/kiruna-app-v0.1."
else
  APP_DIR=""
  note "Local package checks skipped: ${APP_ID} is not in this checkout and cursor/kiruna-app-v0.1 is not fetched."
fi

if [[ -n "$APP_DIR" ]]; then
  check_local "$APP_DIR"
  check_appinspect "$APP_DIR"
fi

if [[ "$LOCAL_ONLY" == yes ]]; then
  print_manual
  [[ "$FAILURES" -eq 0 ]] || die "${FAILURES} check(s) failed."
  exit 0
fi

command -v aws >/dev/null 2>&1 || die "aws CLI is not on PATH. Re-run with --local-only to skip the instance."
INSTANCE_ID=$(resolve_instance) || exit $?
check_remote "$INSTANCE_ID"
print_manual
[[ "$FAILURES" -eq 0 ]] || die "${FAILURES} check(s) failed."
