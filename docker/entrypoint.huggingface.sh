#!/bin/bash
# Single-container bootstrap for the Hugging Face Space image (see root
# Dockerfile). Unlike docker/entrypoint.sh (k3s/Compose - assumes Postgres,
# Redis, MLflow, Prefect, LocalStack already exist as separate containers),
# this script has to bring all of them up itself as background processes in
# THIS one container, since HF Spaces expose exactly one port and give no
# docker-in-docker access. LocalStack itself doesn't need Docker though -
# the root Dockerfile is built FROM localstack/localstack:4.4.0, whose own
# entrypoint just execs `localstack-supervisor` directly from its bundled
# venv (confirmed by reading that script) - this reuses that same binary
# in-process instead of going through LocalStack's separate, newer CLI
# (which does require Docker + an account - a different tool entirely).
# No persistence needed either way: HF Spaces without the paid
# persistent-storage add-on wipe local disk on every restart, so this image
# re-seeds Postgres and retrains from the committed CSVs on every boot, same
# as the k3s/Compose images already do.
set -e

echo "========================================================"
echo "  HUGGING FACE SPACE: BOOTSTRAPPING SINGLE-CONTAINER STACK"
echo "========================================================"

export POSTGRES_USER="${POSTGRES_USER:-user}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-Password}"
export POSTGRES_DB="${POSTGRES_DB:-rossmann}"
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"
# app/db_bootstrap.py builds its own connection from DB_HOST/DB_PORT rather
# than DATABASE_URL - defaults to "postgres" (the k3s/Compose service name),
# which doesn't resolve here.
export DB_HOST="127.0.0.1"
export DB_PORT="5432"
export MLFLOW_TRACKING_URI="http://127.0.0.1:5000"
export PREFECT_API_URL="http://127.0.0.1:4200/api"
export MODEL_URI="${MODEL_URI:-models:/Rossmann_XGBoost_Model/latest}"
# Same S3/LocalStack env vars docker/entrypoint.sh already expects - DATA_STORAGE_ROOT
# is left at its default (s3://...) since real S3 (via the in-container LocalStack
# below) is available here, same as k3s/Compose.
export MLFLOW_S3_ENDPOINT_URL="http://127.0.0.1:4566"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

wait_for_tcp() {
    local host="$1" port="$2" label="$3" max_tries="${4:-60}"
    echo "Waiting for $label ($host:$port)..."
    for i in $(seq 1 "$max_tries"); do
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            exec 3>&- 3<&-
            echo "$label is accepting connections."
            return 0
        fi
        sleep 1
    done
    echo "ERROR: $label did not become reachable after ${max_tries}s."
    exit 1
}

# --- 0. LocalStack (S3 only) ---
echo "Starting LocalStack..."
export SERVICES=s3
export GATEWAY_LISTEN=127.0.0.1:4566
(
    source /opt/code/localstack/.venv/bin/activate
    exec localstack-supervisor
) >/tmp/localstack.log 2>&1 &
wait_for_tcp 127.0.0.1 4566 "LocalStack"

# --- 1. PostgreSQL ---
echo "Starting PostgreSQL..."
PG_VERSION="$(ls /usr/lib/postgresql | head -n1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
PG_DATA="/var/lib/postgresql/data"

if [ ! -s "${PG_DATA}/PG_VERSION" ]; then
    mkdir -p "$PG_DATA"
    chown -R postgres:postgres "$PG_DATA"
    su -s /bin/bash postgres -c "${PG_BIN}/initdb -D ${PG_DATA}" >/tmp/initdb.log 2>&1
fi
su -s /bin/bash postgres -c "${PG_BIN}/pg_ctl -D ${PG_DATA} -l /tmp/postgres.log -w start"
wait_for_tcp 127.0.0.1 5432 "PostgreSQL"

# Role + database are idempotent (fresh cluster every boot anyway, since
# PG_DATA lives on the same wiped-on-restart disk as everything else) -
# guarded regardless in case a future change adds real persistence.
# Double-quoted in the SQL itself - "user" (POSTGRES_USER's default value)
# is a reserved PostgreSQL keyword, not just a role name here.
su -s /bin/bash postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'\"" | grep -q 1 || \
    su -s /bin/bash postgres -c "psql -c \"CREATE ROLE \\\"${POSTGRES_USER}\\\" WITH LOGIN SUPERUSER PASSWORD '${POSTGRES_PASSWORD}';\""
su -s /bin/bash postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1 || \
    su -s /bin/bash postgres -c "createdb -O ${POSTGRES_USER} ${POSTGRES_DB}"

# db/init.sql itself DROPs-then-CREATEs (see db/init.sql) so re-running it
# on an already-initialized database is safe.
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f db/init.sql

# --- 2. Redis ---
echo "Starting Redis..."
redis-server --daemonize yes --maxmemory 256mb --maxmemory-policy allkeys-lru --save "" --logfile /tmp/redis.log
wait_for_tcp 127.0.0.1 6379 "Redis"

# --- 3. Databases (mlflow/prefect/feast dbs must exist before those
# servers start below, or they hang retrying against a nonexistent db) ---
echo "Bootstrapping required databases..."
python app/db_bootstrap.py

# --- 4. Feast credentials substitution (same fix as docker/entrypoint.sh,
# plus rewriting the k3s/Compose service-name hosts to localhost since
# everything now lives in this one container) ---
python3 -c "
import os
path = 'feature_repo/feature_store.yaml'
with open(path) as f:
    content = f.read()
content = content.replace('\${POSTGRES_USER}', os.environ['POSTGRES_USER'])
content = content.replace('\${POSTGRES_PASSWORD}', os.environ['POSTGRES_PASSWORD'])
content = content.replace('@postgres:5432', '@127.0.0.1:5432')
content = content.replace('host: postgres', 'host: 127.0.0.1')
content = content.replace('\"redis:6379\"', '\"127.0.0.1:6379\"')
with open(path, 'w') as f:
    f.write(content)
"

# --- 5. MLflow tracking server (S3 artifact store via the in-container
# LocalStack above, same layout as k3s/Compose) ---
echo "Starting MLflow server..."
python3 -c "
import boto3
from botocore.exceptions import ClientError
s3 = boto3.client('s3', endpoint_url='http://127.0.0.1:4566')
for bucket, prefix in [('rossmann-mlops-dvc-store', 'dvc-store'), ('rossmann-mlflow-artifacts', 'mlflow-artifacts')]:
    try:
        s3.head_bucket(Bucket=bucket)
    except ClientError:
        s3.create_bucket(Bucket=bucket)
        print(f'Created S3 bucket {bucket}')
    s3.put_object(Bucket=bucket, Key=f'{prefix}/')
"
mlflow server \
    --host 127.0.0.1 \
    --port 5000 \
    --workers 1 \
    --backend-store-uri "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/mlflow" \
    --default-artifact-root s3://rossmann-mlflow-artifacts/mlflow-artifacts \
    --allowed-hosts "*" \
    >/tmp/mlflow.log 2>&1 &
wait_for_tcp 127.0.0.1 5000 "MLflow"

# --- 6. Prefect server ---
echo "Starting Prefect server..."
export PREFECT_API_DATABASE_CONNECTION_URL="postgresql+asyncpg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/prefect"
prefect server start --host 127.0.0.1 >/tmp/prefect.log 2>&1 &
python3 -c "
import time, urllib.request, urllib.error
for i in range(60):
    try:
        with urllib.request.urlopen('http://127.0.0.1:4200/api/health', timeout=3) as resp:
            if resp.status == 200:
                print('Prefect API is healthy.')
                raise SystemExit(0)
    except (urllib.error.URLError, ConnectionError, TimeoutError):
        pass
    time.sleep(2)
print('ERROR: Prefect API did not become healthy after 120 seconds.')
raise SystemExit(1)
"

# --- 7. Seed data (reuses existing project script as-is; databases
# already exist from step 3 above) ---
echo "Seeding train/test tables from the committed CSVs..."
python db/seed_db.py

# --- 8. Feast apply/materialize ---
echo "Applying Feast definitions..."
cd feature_repo
feast apply
echo "Materializing features to Redis..."
feast materialize "2010-01-01T00:00:00" "2030-12-31T23:59:59"
cd ..

# --- 8. DVC (S3 remote via the in-container LocalStack) ---
if [ ! -d ".dvc" ]; then
    dvc init --no-scm
fi
dvc remote modify --local storage endpointurl "$MLFLOW_S3_ENDPOINT_URL"
dvc remote modify --local storage access_key_id "$AWS_ACCESS_KEY_ID"
dvc remote modify --local storage secret_access_key "$AWS_SECRET_ACCESS_KEY"
dvc remote modify --local storage use_ssl false

echo "Executing Training Pipeline via Prefect..."
python pipelines/training_pipeline.py

echo "Calculating initial batch predictions for test data..."
python src/predict_initial.py

echo "========================================================"
echo "  SYSTEM READY - LAUNCHING FASTAPI"
echo "========================================================"
exec uvicorn app.main:app --host 0.0.0.0 --port "${APP_PORT:-7860}"
