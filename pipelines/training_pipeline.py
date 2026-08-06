import os
import subprocess
import warnings

from pydantic import PydanticDeprecatedSince20

# prefect==2.14.21's own prefect/input/run_input.py defines a pydantic
# BaseModel using the old class-based `Config` style, which fires a
# PydanticDeprecatedSince20 warning the instant `prefect` is imported -
# entirely inside Prefect's source, not fixable here short of bumping
# Prefect (which requirements.txt deliberately pins against - see the
# comment there on server-schema compatibility). Filtered before the import
# below so it never fires in this process; the same filter also lives in
# pytest.ini for test runs, and in app/main.py for the FastAPI process,
# since each is a separate Python process with its own warnings state.
warnings.filterwarnings(
    "ignore",
    message=r"Support for class-based `config` is deprecated.*",
    category=PydanticDeprecatedSince20,
)
from prefect import flow, task  # noqa: E402

# Point to the root directory
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _dvc_env():
    """Build env for DVC subprocesses, including explicit LocalStack endpoint wiring."""
    env = os.environ.copy()
    endpoint = env.get("MLFLOW_S3_ENDPOINT_URL")
    if endpoint:
        # DVC's direct s3:// stage deps/outs use S3 clients internally, not the
        # DVC remote endpoint setting from .dvc/config.local, so pass the
        # endpoint explicitly for both generic and S3-specific SDK lookups.
        env["AWS_ENDPOINT_URL"] = endpoint
        env["AWS_ENDPOINT_URL_S3"] = endpoint
    return env


def _run_dvc(cmd):
    subprocess.run(cmd, cwd=PROJECT_ROOT, check=True, env=_dvc_env())

@task(name="1. DVC: Data Ingestion", retries=1)
def dvc_ingest():
    print("Triggering DVC Ingest Stage (FORCED)...")
    # Added --force to bypass cache check
    _run_dvc(["dvc", "repro", "--force", "ingest"])

@task(name="2. DVC: Feature Engineering")
def dvc_featurize():
    print("Triggering DVC Feature Engineering Stage...")
    _run_dvc(["dvc", "repro", "featurize"])

@task(name="3. DVC: Model Training")
def dvc_train():
    print("Triggering DVC Training Stage...")
    _run_dvc(["dvc", "repro", "train"])

@task(name="4. DVC: Push to S3 Remote")
def dvc_push():
    # `dvc repro` above only ever updates the LOCAL cache - it never talks to
    # the remote. Actually getting data into S3 needs this separate, explicit
    # step (unlike MLflow, which writes to S3 synchronously inside log_model).
    # Skips gracefully if no S3 endpoint is configured (e.g. LocalStack isn't
    # wired up) rather than failing the whole training run over it.
    if os.getenv("MLFLOW_S3_ENDPOINT_URL"):
        print("Pushing DVC-tracked data to the S3 remote...")
        _run_dvc(["dvc", "push"])
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
