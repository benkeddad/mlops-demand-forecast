#!/bin/bash
# Local dev bootstrap for both infrastructure-adjacent stores:
#   1) LocalStack S3 buckets/prefixes (best effort)
#   2) PostgreSQL seed load from project CSV files (required)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUCKETS=("rossmann-mlops-dvc-store" "rossmann-mlflow-artifacts")
BUCKET_PREFIX_PAIRS=(
    "rossmann-mlops-dvc-store:dvc-store"
    "rossmann-mlops-dvc-store:processed-data"
    "rossmann-mlflow-artifacts:mlflow-artifacts"
)
POSTGRES_PORT="5432"
S3_PORT="4566"

POSTGRES_USER="${POSTGRES_USER:-user}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-Password}"
POSTGRES_DB="${POSTGRES_DB:-rossmann}"
SEED_VENV_DIR="$REPO_ROOT/.venv-seed-db"
SEED_VENV_PYTHON="$SEED_VENV_DIR/bin/python3"

# k3s's built-in ServiceLB binds a LoadBalancer Service's port directly on
# the WSL host (127.0.0.1) - but that hostPort path has proven unreliable
# for real wire-protocol traffic (Postgres connections there time out
# consistently, even though the pod itself is healthy). The Service's
# ClusterIP, reachable directly since the WSL host IS the k3s node, does
# not have this problem - prefer it whenever k3s is present, and fall back
# to 127.0.0.1 for Compose (a plain, reliable Docker port publish there).
resolve_cluster_ip() {
    local service_name="$1"
    if command -v k3s >/dev/null 2>&1; then
        k3s kubectl get svc "$service_name" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
    fi
}

POSTGRES_HOST="${POSTGRES_HOST:-$(resolve_cluster_ip postgres)}"
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"

S3_HOST="$(resolve_cluster_ip localstack)"
S3_HOST="${S3_HOST:-127.0.0.1}"
S3_ENDPOINT="http://${S3_HOST}:${S3_PORT}"

DATABASE_URL="${DATABASE_URL:-postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}}"

localstack_healthy() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$S3_ENDPOINT/_localstack/health" 2>/dev/null)" = "200" ]
}

echo "Checking LocalStack (S3) at $S3_ENDPOINT ..."
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

    if command -v aws >/dev/null 2>&1; then
        export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
        export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
        export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

        for BUCKET in "${BUCKETS[@]}"; do
            if aws --endpoint-url="$S3_ENDPOINT" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
                echo "S3 bucket '$BUCKET' already exists in LocalStack."
            elif aws --endpoint-url="$S3_ENDPOINT" s3 mb "s3://$BUCKET" >/dev/null 2>&1; then
                echo "Created S3 bucket '$BUCKET' in LocalStack."
            else
                echo "Could not create S3 bucket '$BUCKET' - continuing."
            fi
        done

        for PAIR in "${BUCKET_PREFIX_PAIRS[@]}"; do
            BUCKET="${PAIR%%:*}"
            PREFIX="${PAIR##*:}"
            if aws --endpoint-url="$S3_ENDPOINT" s3api head-object --bucket "$BUCKET" --key "$PREFIX/" >/dev/null 2>&1; then
                echo "Folder '$PREFIX/' already exists in bucket '$BUCKET'."
            elif aws --endpoint-url="$S3_ENDPOINT" s3api put-object --bucket "$BUCKET" --key "$PREFIX/" >/dev/null 2>&1; then
                echo "Created folder '$PREFIX/' in bucket '$BUCKET'."
            else
                echo "Could not create folder '$PREFIX/' in bucket '$BUCKET' - continuing."
            fi
        done
    else
        echo "AWS CLI is not installed - skipping S3 bucket setup."
    fi
else
    echo "LocalStack is not reachable - skipping S3 bucket setup."
fi

echo "Checking PostgreSQL on ${POSTGRES_HOST}:${POSTGRES_PORT} ..."
POSTGRES_READY=0
for i in $(seq 1 30); do
    # Open+close in a subshell only - writing any byte (e.g. `echo >`) here
    # is a stray, invalid Postgres startup packet, which can leave a simple
    # L4 proxy in front of Postgres (e.g. k3s's ServiceLB) in a state that
    # drops the very next real connection attempt (db/seed_db.py retries its
    # own connection too, as a second line of defense). The subshell closes
    # fd 3 automatically on exit, without sending any data.
    if (exec 3<>"/dev/tcp/${POSTGRES_HOST}/${POSTGRES_PORT}") 2>/dev/null; then
        POSTGRES_READY=1
        break
    fi
    sleep 2
done

if [ "$POSTGRES_READY" != "1" ]; then
    echo "ERROR: PostgreSQL is not reachable on ${POSTGRES_HOST}:${POSTGRES_PORT}."
    exit 1
fi

echo "PostgreSQL is reachable. Running database seed from project CSV files..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required in WSL to run db/seed_db.py."
    exit 1
fi

if [ ! -d "$SEED_VENV_DIR" ]; then
    echo "Creating dedicated seed virtual environment at $SEED_VENV_DIR ..."
    python3 -m venv "$SEED_VENV_DIR"
fi

if [ ! -x "$SEED_VENV_PYTHON" ]; then
    echo "ERROR: Seed venv python not found at $SEED_VENV_PYTHON."
    exit 1
fi

# Keep the seed venv minimal and focused on db/seed_db.py requirements.
if ! "$SEED_VENV_PYTHON" -c "import pandas, sqlalchemy, psycopg2" >/dev/null 2>&1; then
    echo "Installing seed dependencies into $SEED_VENV_DIR ..."
    "$SEED_VENV_PYTHON" -m pip install --upgrade pip >/dev/null
    "$SEED_VENV_PYTHON" -m pip install --no-cache-dir pandas sqlalchemy psycopg2-binary
fi

DATABASE_URL="$DATABASE_URL" "$SEED_VENV_PYTHON" db/seed_db.py

echo "LocalStack/PostgreSQL bootstrap finished."
