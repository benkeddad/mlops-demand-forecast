#!/bin/bash
set -e

echo "========================================================"
echo "  INITIALIZING MLOPS PIPELINE ENVIRONMENT"
echo "========================================================"

# --- READINESS FIX ---
# This used to be a blind `sleep 30`. That's a guess, not a check: on a
# fresh machine's first `docker compose up --build` (cold image pulls, no
# page cache, Postgres running its own first-boot init, Prefect's server
# running its own DB migrations against the `prefect` database), 30 seconds
# isn't guaranteed to be enough - and api's `depends_on` in
# deploy/docker-compose.yaml only waits for the postgres/mlflow/prefect
# *containers* to start, not for Postgres to accept connections or for
# Prefect's API to actually be serving. db_bootstrap.py below has no retry
# of its own, so a still-starting Postgres would make it fail outright -
# and because this script runs under `set -e`, that failure would kill the
# whole container before uvicorn ever starts. Poll for real readiness
# instead, bounded so a genuinely broken dependency still fails loudly
# rather than hanging forever.
wait_for_tcp() {
    local host="$1" port="$2" label="$3" max_tries="${4:-60}"
    echo "Waiting for $label ($host:$port)..."
    for i in $(seq 1 "$max_tries"); do
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            exec 3>&- 3<&-
            echo "$label is accepting connections."
            return 0
        fi
        sleep 2
    done
    echo "ERROR: $label did not become reachable after $((max_tries * 2)) seconds."
    exit 1
}

wait_for_tcp postgres 5432 "PostgreSQL"
wait_for_tcp redis 6379 "Redis"

# Prefect's server does its own DB migrations against the `prefect` Postgres
# database on first boot before it answers requests - an open TCP port on
# 4200 doesn't guarantee that's finished, only that the process has started
# listening. Poll the actual health endpoint (stdlib urllib only - no curl in
# this image) before training_pipeline.py below tries to report flow state
# to it via PREFECT_API_URL.
echo "Waiting for Prefect API..."
python3 -c "
import time
import urllib.request
import urllib.error

url = 'http://prefect:4200/api/health'
for i in range(60):
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            if resp.status == 200:
                print('Prefect API is healthy.')
                raise SystemExit(0)
    except (urllib.error.URLError, ConnectionError, TimeoutError):
        pass
    time.sleep(2)
print('ERROR: Prefect API did not become healthy after 120 seconds.')
raise SystemExit(1)
"

# --- INDUSTRIAL PROVISIONING FIX ---
# This ensures 'feast' and other databases exist even if volumes are pre-populated
echo "Bootstrapping required databases..."
python app/db_bootstrap.py
# -----------------------------------

# --- FEAST CREDENTIALS FIX ---
# feature_repo/feature_store.yaml keeps ${POSTGRES_USER}/${POSTGRES_PASSWORD}
# placeholders committed (documents intent, never bakes in a real password),
# but Feast itself has no built-in env-var substitution for this file - it
# reads the YAML literally. Substitute them here, in-place, before Feast ever
# reads it, using whatever POSTGRES_USER/POSTGRES_PASSWORD this container
# actually got (from the Secret/`.env`), instead of a hardcoded default.
python3 -c "
import os
path = 'feature_repo/feature_store.yaml'
with open(path) as f:
    content = f.read()
content = content.replace('\${POSTGRES_USER}', os.environ['POSTGRES_USER'])
content = content.replace('\${POSTGRES_PASSWORD}', os.environ['POSTGRES_PASSWORD'])
with open(path, 'w') as f:
    f.write(content)
"
# -----------------------------

echo "Applying Feast definitions..."
cd feature_repo
feast apply

# --- THE FEAST FIX IS HERE ---
echo "Materializing features to Redis..."
# Using a massive window to guarantee 2013-2015 data is caught regardless of TTL or current date
feast materialize "2010-01-01T00:00:00" "2030-12-31T23:59:59"
cd ..
# -----------------------------

# --- THE DVC FIX IS HERE ---
# The image ships a real, committed .dvc/config (S3 remote included) copied in
# at build time, so only initialize DVC if that's somehow missing - `dvc init
# --force` on an already-initialized project wipes .dvc/config, which would
# silently drop the team's shared S3 remote on every single container boot.
if [ ! -d ".dvc" ]; then
    echo "No .dvc directory found - initializing DVC in the live volume..."
    dvc init --no-scm
else
    echo "DVC already initialized (remote 'storage' config present) - skipping re-init."
fi

# --- DVC S3 ENDPOINT (LocalStack) ---
# The committed .dvc/config deliberately has no endpoint override, so it stays
# portable to real AWS. A LocalStack endpoint has to live in .dvc/config.local
# instead (never committed) - generated fresh here from the same S3 env vars
# MLflow already gets (the s3-credentials Secret/Compose env block), rather
# than baked into the image or hand-maintained. Conditional: if those env vars
# aren't set (e.g. no LocalStack wired up), this is skipped and DVC just uses
# whatever's already in the committed config (real AWS creds, or nothing).
if [ -n "$MLFLOW_S3_ENDPOINT_URL" ]; then
    echo "Configuring DVC's S3 remote for LocalStack ($MLFLOW_S3_ENDPOINT_URL)..."
    dvc remote modify --local storage endpointurl "$MLFLOW_S3_ENDPOINT_URL"
    dvc remote modify --local storage access_key_id "$AWS_ACCESS_KEY_ID"
    dvc remote modify --local storage secret_access_key "$AWS_SECRET_ACCESS_KEY"
    dvc remote modify --local storage use_ssl false

    # LocalStack has no persistence - if its pod ever gets recreated outside
    # the deploy scripts (crash-loop, manual restart, etc.), both buckets
    # vanish and training fails with NoSuchBucket. Self-heal on every boot
    # instead of only relying on scripts/setup_localstack_and_postgres.sh.
    python3 -c "
import boto3
from botocore.exceptions import ClientError
s3 = boto3.client('s3', endpoint_url='$MLFLOW_S3_ENDPOINT_URL')
for bucket, prefix in [('rossmann-mlops-dvc-store', 'dvc-store'), ('rossmann-mlflow-artifacts', 'mlflow-artifacts')]:
    try:
        s3.head_bucket(Bucket=bucket)
    except ClientError:
        s3.create_bucket(Bucket=bucket)
        print(f'Created S3 bucket {bucket}')
    s3.put_object(Bucket=bucket, Key=f'{prefix}/')
"
fi
# -----------------------

echo "Executing Training Pipeline via Prefect..."
python pipelines/training_pipeline.py
# -----------------------

echo "Calculating initial batch predictions for test data..."
python src/predict_initial.py

echo "========================================================"
echo "  SYSTEM READY - LAUNCHING FASTAPI"
echo "========================================================"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000