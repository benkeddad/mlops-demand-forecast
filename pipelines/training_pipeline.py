import os
import subprocess
from prefect import flow, task

# Point to the root directory
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

@task(name="1. DVC: Data Ingestion", retries=1)
def dvc_ingest():
    print("Triggering DVC Ingest Stage...")
    subprocess.run(["dvc", "repro", "ingest"], cwd=PROJECT_ROOT, check=True)

@task(name="2. DVC: Feature Engineering")
def dvc_featurize():
    print("Triggering DVC Feature Engineering Stage...")
    subprocess.run(["dvc", "repro", "featurize"], cwd=PROJECT_ROOT, check=True)

@task(name="3. DVC: Model Training")
def dvc_train():
    print("Triggering DVC Training Stage...")
    subprocess.run(["dvc", "repro", "train"], cwd=PROJECT_ROOT, check=True)

@flow(name="Rossmann-Enterprise-Pipeline")
def ml_training_pipeline():
    # Prefect tracks the execution order, DVC handles the actual caching logic
    dvc_ingest()
    dvc_featurize()
    dvc_train()

if __name__ == "__main__":
    ml_training_pipeline()