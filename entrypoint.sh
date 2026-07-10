#!/bin/bash
set -e

echo "========================================================"
echo "  INITIALIZING MLOPS PIPELINE ENVIRONMENT"
echo "========================================================"

echo "Waiting 30 seconds for database and cache to initialize..."
sleep 30

echo "Applying Feast definitions..."
cd feature_repo
feast apply

echo "Materializing features to Redis..."
CURRENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")
feast materialize-incremental $CURRENT_TIMESTAMP
cd ..

echo "Loading initial raw CSV data into PostgreSQL..."
python src/seed_db.py

# --- THE FIX IS HERE ---
echo "Initializing DVC in the live volume..."
dvc init --no-scm --force

echo "Executing Training Pipeline via Prefect..."

python pipelines/training_pipeline.py
# -----------------------

echo "Calculating initial batch predictions for test data..."
python src/predict_initial.py

echo "========================================================"
echo "  SYSTEM READY - LAUNCHING FASTAPI"
echo "========================================================"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000