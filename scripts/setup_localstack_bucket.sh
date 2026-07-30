#!/bin/bash
# Best-effort LocalStack + S3 bucket bootstrap for local dev.
#
# Kept as its own real .sh file (same reason as install_terraform.sh):
# cmd.exe's batch parser corrupts long bash one-liners, so composite logic
# like this lives here instead of inline in the .bat scripts.
#
# This is NOT a hard requirement for any deploy script that calls it: DVC
# works fine against its local cache/volume, and MLflow works fine against
# its PersistentVolumeClaim/Docker volume, with no S3 remote reachable at
# all. This script only gives DVC (`dvc push`/`dvc pull`) and MLflow (model
# artifact storage, via `--default-artifact-root s3://...`) something real
# to talk to when LocalStack happens to be available.
#
# LocalStack itself is no longer started here - both deploy paths now bring
# it up declaratively before this script ever runs (a Compose service with
# its own healthcheck, or a Terraform-managed k3s Deployment/Service), so
# this only ever needs to check whether it's actually responding.
#
# Behavior:
#   1. If LocalStack is reachable (127.0.0.1:4566 healthy) - create buckets.
#   2. Else - skip entirely, no error. DVC/MLflow just use their local
#      cache/volume instead of S3.
#   3. If the `aws` CLI isn't installed, skip bucket creation, no error.
#
# Always exits 0 - none of the above blocks the rest of the deploy scripts.

# .dvc/config's remote name/region (DVC) and deploy/terraform's
# --default-artifact-root / docker-compose.yaml's mlflow command (MLflow)
# must match these exactly. Each bucket's own prefix goes with it, so both
# get pre-created as an explicit empty "folder" marker (not required for S3
# itself, but MLflow/DVC don't have to be the ones to create it first).
BUCKETS=("rossmann-mlops-dvc-store" "rossmann-mlflow-artifacts")
PREFIXES=("dvc-store" "mlflow-artifacts")
ENDPOINT="http://127.0.0.1:4566"

localstack_healthy() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$ENDPOINT/_localstack/health" 2>/dev/null)" = "200" ]
}

echo "Checking LocalStack (S3) at $ENDPOINT ..."

# A few retries, not a hard requirement to start anything: on k3s, the port
# to $ENDPOINT is a `kubectl port-forward` tunnel that can take a moment to
# establish even after the pod itself is confirmed ready.
LOCALSTACK_READY=0
for i in $(seq 1 10); do
    if localstack_healthy; then
        LOCALSTACK_READY=1
        break
    fi
    sleep 2
done

if [ "$LOCALSTACK_READY" = "1" ]; then
    echo "LocalStack is reachable."
else
    echo "LocalStack is not reachable - skipping S3 bucket setup."
    echo "DVC/MLflow will fall back to their local cache/volume."
    exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "AWS CLI is not installed - cannot create the S3 buckets."
    echo "DVC/MLflow will fall back to their local cache/volume."
    exit 0
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

for BUCKET in "${BUCKETS[@]}"; do
    if aws --endpoint-url="$ENDPOINT" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
        echo "S3 bucket '$BUCKET' already exists in LocalStack."
    elif aws --endpoint-url="$ENDPOINT" s3 mb "s3://$BUCKET" >/dev/null 2>&1; then
        echo "Created S3 bucket '$BUCKET' in LocalStack."
    else
        echo "Could not create S3 bucket '$BUCKET' - falling back to local cache/volume for it."
    fi
done

for i in "${!BUCKETS[@]}"; do
    BUCKET="${BUCKETS[$i]}"
    PREFIX="${PREFIXES[$i]}"
    if aws --endpoint-url="$ENDPOINT" s3api head-object --bucket "$BUCKET" --key "$PREFIX/" >/dev/null 2>&1; then
        echo "Folder '$PREFIX/' already exists in bucket '$BUCKET'."
    elif aws --endpoint-url="$ENDPOINT" s3api put-object --bucket "$BUCKET" --key "$PREFIX/" >/dev/null 2>&1; then
        echo "Created folder '$PREFIX/' in bucket '$BUCKET'."
    else
        echo "Could not create folder '$PREFIX/' in bucket '$BUCKET'."
    fi
done

exit 0
