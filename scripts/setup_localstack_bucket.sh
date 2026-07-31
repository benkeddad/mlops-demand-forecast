#!/bin/bash
# Self-healing LocalStack + S3 bucket bootstrap for WSL dev.

BUCKETS=("rossmann-mlops-dvc-store" "rossmann-mlflow-artifacts")
PREFIXES=("dvc-store" "mlflow-artifacts")

# Auto-detect WSL primary node IP alongside loopback
NODE_IP=$(hostname -I | awk '{print $1}')
ENDPOINTS=("http://127.0.0.1:4566" "http://${NODE_IP}:4566")

localstack_healthy() {
    local target="$1"
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$target/_localstack/health" 2>/dev/null)" = "200" ]
}

ACTIVE_ENDPOINT=""

echo "Checking LocalStack (S3) availability across interfaces..."

for i in $(seq 1 10); do
    for ep in "${ENDPOINTS[@]}"; do
        if localstack_healthy "$ep"; then
            ACTIVE_ENDPOINT="$ep"
            break 2
        fi
    done
    sleep 2
done

if [ -n "$ACTIVE_ENDPOINT" ]; then
    echo "LocalStack is reachable at $ACTIVE_ENDPOINT."
    ENDPOINT="$ACTIVE_ENDPOINT"
    export AWS_ENDPOINT_URL="$ENDPOINT"
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

# Bucket creation against detected active endpoint
for BUCKET in "${BUCKETS[@]}"; do
    if aws --endpoint-url="$ENDPOINT" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
        echo "S3 bucket '$BUCKET' already exists in LocalStack."
    elif aws --endpoint-url="$ENDPOINT" s3 mb "s3://$BUCKET" >/dev/null 2>&1; then
        echo "Created S3 bucket '$BUCKET' in LocalStack."
    else
        echo "Could not create S3 bucket '$BUCKET' - falling back to local cache/volume for it."
    fi
done

# Folder marker creation against detected active endpoint
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