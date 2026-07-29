#!/bin/bash
# Best-effort LocalStack + S3 bucket bootstrap for local dev.
#
# Kept as its own real .sh file (same reason as install_terraform.sh):
# cmd.exe's batch parser corrupts long bash one-liners, so composite logic
# like this lives here instead of inline in the .bat scripts.
#
# This is NOT a hard requirement for any deploy script that calls it: DVC
# works fine against its local cache/volume with no S3 remote reachable at
# all. This script only gives `dvc push`/`dvc pull` something real to talk
# to when LocalStack happens to be available - see .dvc/config.local
# (gitignored, per-machine) for the endpoint/creds that must match this
# bucket, and .dvc/config (committed) for the bucket name/region.
#
# Behavior:
#   1. If LocalStack is already running (127.0.0.1:4566 healthy) - use it.
#   2. Else, if the `localstack` CLI is installed - start it and wait for
#      it to become healthy.
#   3. Else - LocalStack isn't installed; skip entirely, no error. DVC will
#      just use its local cache/volume instead of the S3 remote.
#   4. If LocalStack ends up reachable AND the `aws` CLI is installed,
#      idempotently create the bucket .dvc/config already points at.
#   5. If the `aws` CLI isn't installed, skip bucket creation, no error.
#
# Always exits 0 - none of the above blocks the rest of the deploy scripts.

BUCKET="rossmann-mlops-dvc-store"
ENDPOINT="http://127.0.0.1:4566"

localstack_healthy() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$ENDPOINT/_localstack/health" 2>/dev/null)" = "200" ]
}

echo "Checking LocalStack (S3) at $ENDPOINT ..."

if localstack_healthy; then
    echo "LocalStack is already running."
elif command -v localstack >/dev/null 2>&1; then
    echo "LocalStack is installed but not running - starting it..."
    localstack start -d >/dev/null 2>&1

    for i in $(seq 1 20); do
        if localstack_healthy; then
            break
        fi
        sleep 3
    done

    if localstack_healthy; then
        echo "LocalStack started successfully."
    else
        echo "LocalStack did not become healthy in time - skipping S3 bucket setup."
        echo "DVC will fall back to its local cache/volume."
        exit 0
    fi
else
    echo "LocalStack is not installed - skipping S3 bucket setup."
    echo "DVC will fall back to its local cache/volume."
    exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "AWS CLI is not installed - cannot create the S3 bucket."
    echo "DVC will fall back to its local cache/volume."
    exit 0
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if aws --endpoint-url="$ENDPOINT" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo "S3 bucket '$BUCKET' already exists in LocalStack."
elif aws --endpoint-url="$ENDPOINT" s3 mb "s3://$BUCKET" >/dev/null 2>&1; then
    echo "Created S3 bucket '$BUCKET' in LocalStack."
else
    echo "Could not create S3 bucket '$BUCKET' - DVC will fall back to its local cache/volume."
fi

exit 0
