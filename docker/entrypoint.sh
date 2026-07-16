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