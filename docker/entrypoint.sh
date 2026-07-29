#!/bin/bash
set -e

echo "========================================================"
echo "  INITIALIZING MLOPS PIPELINE ENVIRONMENT"
echo "========================================================"

echo "Waiting 30 seconds for database and cache to initialize..."
sleep 30

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

echo "Loading initial raw CSV data into PostgreSQL..."
python src/seed_db.py

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