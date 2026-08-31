"""Prefect flow: retrieve a past MLflow run, optionally re-execute training
via `dvc repro train`, and log a pass/fail reproducibility audit back to
MLflow. Ported from the standalone rossmann-forecasting-automated-model-training
project - same DVC-subprocess approach as pipelines/training_pipeline.py in
this repo, since `dvc repro` is a CLI tool either way.

Run directly:
    python pipelines/reproduction_pipeline.py <run_id> [--execute-retrain] [--tolerance 0.001]

Invoked by the API via app/routers/reproducibility.py, the same way
app/main.py's lifespan shells out to pipelines/serve_deployment.py.
"""
import argparse
import json
import os
import subprocess
import sys
import warnings
from pathlib import Path

from pydantic import PydanticDeprecatedSince20

# Same root cause and same reasoning as the identical filter in
# pipelines/training_pipeline.py and app/main.py: fires the instant prefect
# is imported, entirely inside prefect==2.14.21's own source.
warnings.filterwarnings(
    "ignore",
    message=r"Support for class-based `config` is deprecated.*",
    category=PydanticDeprecatedSince20,
)
from prefect import flow, task  # noqa: E402

import mlflow  # noqa: E402

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT / "src"))
from reproduce_from_mlflow import retrieve_reproduction_package  # noqa: E402

MLFLOW_URI = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
REPRO_EXPERIMENT = os.getenv("REPRO_EXPERIMENT_NAME", "Rossmann_Reproducibility_Audit")


def _dvc_env():
    """Same LocalStack S3 endpoint wiring as pipelines/training_pipeline.py's
    _dvc_env() - DVC's direct s3:// stage deps/outs use S3 clients
    internally, not the DVC remote endpoint from .dvc/config.local."""
    env = os.environ.copy()
    endpoint = env.get("MLFLOW_S3_ENDPOINT_URL")
    if endpoint:
        env["AWS_ENDPOINT_URL"] = endpoint
        env["AWS_ENDPOINT_URL_S3"] = endpoint
    return env


def _run(cmd, cwd=PROJECT_ROOT):
    return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, env=_dvc_env())


@task(name="Retrieve MLflow run package")
def retrieve_package(run_id: str) -> str:
    return str(retrieve_reproduction_package(run_id))


@task(name="Optional DVC retrain and verify")
def verify_reproduction(package_dir: str, execute_retrain: bool = False, tolerance: float = 1e-3) -> dict:
    package = Path(package_dir)
    manifest = json.loads((package / "reproduction_manifest.json").read_text(encoding="utf-8"))
    result = {"source_run_id": manifest["run_id"], "execute_retrain": execute_retrain, "checks": {}, "reproducible": False}
    result["checks"]["metadata_downloaded"] = True
    result["checks"]["dataset_hash_match"] = manifest.get("dataset_verification", {}).get("match")

    if execute_retrain:
        pull = _run(["dvc", "pull"])
        checkout = _run(["dvc", "checkout"])
        repro = _run(["dvc", "repro", "train"])
        result["checks"]["dvc_pull_success"] = pull.returncode == 0
        result["checks"]["dvc_checkout_success"] = checkout.returncode == 0
        result["checks"]["dvc_repro_train_success"] = repro.returncode == 0
        if repro.returncode != 0:
            result["dvc_repro_stderr_tail"] = repro.stderr[-2000:]
        metrics_path = PROJECT_ROOT / "metrics" / "train_metrics.json"
        if metrics_path.exists():
            reproduced = json.loads(metrics_path.read_text(encoding="utf-8"))
            original = manifest.get("loaded_artifacts", {}).get("train_metrics") or {}
            result["original_metrics"] = original
            result["reproduced_metrics"] = reproduced
            deltas = {}
            ok = True
            for key, original_value in original.items():
                if isinstance(original_value, (int, float)) and key in reproduced:
                    delta = abs(float(reproduced[key]) - float(original_value))
                    deltas[key] = delta
                    ok = ok and delta <= tolerance
            result["metric_delta"] = deltas
            result["checks"]["metrics_within_tolerance"] = ok
    else:
        result["note"] = "Retrieval-only verification. Set execute_retrain=true for full DVC rerun."

    result["reproducible"] = all(v is True for v in result["checks"].values() if v is not None)
    report = package / "reproduction_report.json"
    report.write_text(json.dumps(result, indent=2), encoding="utf-8")

    mlflow.set_tracking_uri(MLFLOW_URI)
    mlflow.set_registry_uri(os.getenv("MLFLOW_REGISTRY_URI", MLFLOW_URI))
    mlflow.set_experiment(REPRO_EXPERIMENT)
    with mlflow.start_run(run_name=f"reproduce_{manifest['run_id']}"):
        mlflow.set_tag("source_run_id", manifest["run_id"])
        mlflow.set_tag("reproducible", str(result["reproducible"]))
        mlflow.log_artifact(str(package / "reproduction_manifest.json"), artifact_path="reproduction")
        mlflow.log_artifact(str(report), artifact_path="reproduction")
        for key, value in result.get("metric_delta", {}).items():
            mlflow.log_metric(f"delta_{key}", value)
    return result


@flow(name="Model-Reproduction", log_prints=True)
def reproduce_model_flow(run_id: str, execute_retrain: bool = False, tolerance: float = 1e-3):
    package_dir = retrieve_package(run_id)
    return verify_reproduction(package_dir, execute_retrain=execute_retrain, tolerance=tolerance)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id")
    parser.add_argument("--execute-retrain", action="store_true")
    parser.add_argument("--tolerance", type=float, default=1e-3)
    args = parser.parse_args()
    print(reproduce_model_flow(args.run_id, execute_retrain=args.execute_retrain, tolerance=args.tolerance))
