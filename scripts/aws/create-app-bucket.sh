#!/usr/bin/env bash
# Create the S3 bucket used to hand the demo app to the Splunk host.
# No account id, access key, password, token, or license is stored here.
set -euo pipefail

readonly DEFAULT_REGION=eu-north-1
readonly DEFAULT_APP_BUCKET=kiruna-splunk-demo-app

usage() {
  cat <<EOF
Create the demo app bucket in ${DEFAULT_REGION}.

The bucket name is stored here as ${DEFAULT_APP_BUCKET}.
Override it with --app-bucket or APP_BUCKET. The install script reads the
same name.

  aws s3api create-bucket \\
    --bucket ${DEFAULT_APP_BUCKET} \\
    --region ${DEFAULT_REGION} \\
    --create-bucket-configuration LocationConstraint=${DEFAULT_REGION}

If this account already owns the bucket, the command says so and exits 0.
Public access is blocked, and new objects use AES-256 (SSE-S3).

Optional: --profile / AWS_PROFILE. --region must stay ${DEFAULT_REGION}.
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
APP_BUCKET=${APP_BUCKET:-$DEFAULT_APP_BUCKET}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --profile) [[ $# -ge 2 ]] || die "--profile needs a value"; PROFILE=$2; shift 2 ;;
    --profile=*) PROFILE=${1#*=}; shift ;;
    --region) [[ $# -ge 2 ]] || die "--region needs a value"; AWS_REGION=$2; shift 2 ;;
    --region=*) AWS_REGION=${1#*=}; shift ;;
    --app-bucket) [[ $# -ge 2 ]] || die "--app-bucket needs a value"; APP_BUCKET=$2; shift 2 ;;
    --app-bucket=*) APP_BUCKET=${1#*=}; shift ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || AWS_REGION=$DEFAULT_REGION
[[ "$AWS_REGION" == "$DEFAULT_REGION" ]] || die "This demo bucket is in ${DEFAULT_REGION}. Refusing region ${AWS_REGION}."
[[ "$APP_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "Bucket name must be a DNS-style S3 name."
[[ "$APP_BUCKET" != *..* ]] || die "Bucket name must not contain '..'."
command -v aws >/dev/null 2>&1 || die "aws CLI is not on PATH."

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

err=$(mktemp)
trap 'rm -f "$err"' EXIT
set +e
aws_cli s3api create-bucket \
  --bucket "$APP_BUCKET" \
  --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
  >/dev/null 2>"$err"
rc=$?
set -e
if ((rc != 0)); then
  if grep -q 'BucketAlreadyOwnedByYou' "$err"; then
    note "Bucket ${APP_BUCKET} already exists in this account."
  elif grep -q 'BucketAlreadyExists' "$err"; then
    die "Bucket name ${APP_BUCKET} is owned by another account. Set APP_BUCKET to a different name and run this again."
  else
    cat "$err" >&2
    exit 1
  fi
else
  note "Created bucket ${APP_BUCKET} in ${AWS_REGION}."
fi

location=$(aws_cli s3api get-bucket-location --bucket "$APP_BUCKET" --query 'LocationConstraint' --output text)
if [[ "$location" != "$AWS_REGION" ]]; then
  die "Bucket ${APP_BUCKET} is in ${location}, not ${AWS_REGION}."
fi

aws_cli s3api put-public-access-block \
  --bucket "$APP_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

tmp_dir=$(mktemp -d)
cat >"${tmp_dir}/encryption.json" <<'EOF'
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }
  ]
}
EOF
aws_cli s3api put-bucket-encryption \
  --bucket "$APP_BUCKET" \
  --server-side-encryption-configuration "file://${tmp_dir}/encryption.json"
rm -rf "$tmp_dir"

printf 'APP_BUCKET=%s\n' "$APP_BUCKET"
note "Install the app with: bash scripts/aws/demo-pipeline.sh --after-manual-gate"
note "That command reads APP_BUCKET. The default is ${DEFAULT_APP_BUCKET}."
