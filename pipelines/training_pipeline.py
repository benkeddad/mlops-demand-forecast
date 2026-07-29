import os
import sys
import subprocess
from prefect import flow, task

# Point to the root directory
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

@task(name="1. DVC: Data Ingestion", retries=1)
def dvc_ingest():
    print("Triggering DVC Ingest Stage (FORCED)...")
    # Added --force to bypass cache check
    subprocess.run(["dvc", "repro", "--force", "ingest"], cwd=PROJECT_ROOT, check=True)

@task(name="2. DVC: Feature Engineering")
def dvc_featurize():
    print("Triggering DVC Feature Engineering Stage...")
    subprocess.run(["dvc", "repro", "featurize"], cwd=PROJECT_ROOT, check=True)

@task(name="3. DVC: Model Training")
def dvc_train():
    print("Triggering DVC Training Stage...")
    subprocess.run(["dvc", "repro", "train"], cwd=PROJECT_ROOT, check=True)

@task(name="4. DVC: Push to S3 Remote")
def dvc_push():
    # `dvc repro` above only ever updates the LOCAL cache - it never talks to
    # the remote. Actually getting data into S3 needs this separate, explicit
    # step (unlike MLflow, which writes to S3 synchronously inside log_model).
    # Skips gracefully if no S3 endpoint is configured (e.g. LocalStack isn't
    # wired up) rather than failing the whole training run over it.
    if os.getenv("MLFLOW_S3_ENDPOINT_URL"):
        print("Pushing DVC-tracked data to the S3 remote...")
        subprocess.run(["dvc", "push"], cwd=PROJECT_ROOT, check=True)
    else:
        print("No S3 endpoint configured - skipping dvc push (data stays in the local cache only).")

@flow(name="Rossmann-Enterprise-Pipeline")
def ml_training_pipeline():
    # Prefect tracks the execution order, DVC handles the actual caching logic
    dvc_ingest()
    dvc_featurize()
    dvc_train()
    dvc_push()

if __name__ == "__main__":
    ml_training_pipeline()
    print("Pipeline script finished")
