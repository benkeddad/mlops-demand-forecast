#!/usr/bin/env python3
"""Retrieves everything needed to inspect or reproduce a past training run:
downloads the MLflow run's metadata and artifacts, and checks whether the
data currently at DATA_STORAGE_ROOT still hashes the same as what produced
it (src/train.py logs that hash as the `dataset_sha256` param).

Ported from the standalone rossmann-forecasting-automated-model-training
project's src/reproduce_from_mlflow.py, adapted to this project's actual
data layout: that version assumed a local data/processed/ parquet file;
this one reads through data.py's get_storage_options() since training data
here lives on S3 (or a local dir on Hugging Face Spaces - see data.py).
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import mlflow
import pandas as pd
from mlflow.artifacts import download_artifacts
from mlflow.tracking import MlflowClient

# Runs standalone (python src/reproduce_from_mlflow.py <run_id>) as well as
# imported from pipelines/reproduction_pipeline.py - src/ isn't on sys.path
# in the latter case, so add it the same way pipelines/reproduction_pipeline.py
# adds src/ for its own import of this module.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from data import DATA_STORAGE_ROOT, dataset_fingerprint, get_storage_options  # noqa: E402


def _write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str), encoding="utf-8")


def _load_json_if_exists(path: Optional[Path]) -> Optional[Any]:
    if path and path.exists() and path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return None
    return None


def _find_file(root: Path, filename: str) -> Optional[Path]:
    matches = list(root.rglob(filename))
    return matches[0] if matches else None


def _fingerprint_current_data(path: str) -> Optional[str]:
    """Reads the parquet at `path` (S3 or local, per get_storage_options())
    and fingerprints it the same way src/train.py fingerprinted it at
    training time. Returns None (with a warning, not an exception) if the
    file is missing or unreadable - a reproduction check should report
    "can't verify" rather than crash the whole retrieval."""
    try:
        df = pd.read_parquet(path, storage_options=get_storage_options())
        return dataset_fingerprint(df)
    except Exception as exc:
        print(f"[WARN] Could not compute dataset fingerprint for {path}: {exc}")
        return None


def _write_reproduce_commands(path: Path, manifest: Dict[str, Any]) -> None:
    git_commit = manifest.get("tags", {}).get("git_commit")
    dataset_sha = manifest.get("params", {}).get("dataset_sha256")
    lines = ["#!/usr/bin/env bash", "set -euo pipefail", "echo '[INFO] Reproducing MLflow run package'"]
    if git_commit and git_commit != "unknown":
        lines += [f"git checkout {git_commit}"]
    else:
        lines += ["echo '[WARN] No git_commit tag found in MLflow run. Skipping git checkout.'"]
    lines += [
        "if command -v dvc >/dev/null 2>&1; then dvc pull || true; dvc checkout || true; else echo '[WARN] dvc not installed'; fi",
        f"echo '[INFO] Expected dataset_sha256 from MLflow: {dataset_sha}'" if dataset_sha else "echo '[WARN] No dataset_sha256 param found'",
        "echo '[INFO] Rerun with: dvc repro train'",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")
    try:
        path.chmod(0o755)
    except Exception:
        pass


def retrieve_reproduction_package(run_id: str) -> Path:
    tracking_uri = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
    registry_uri = os.getenv("MLFLOW_REGISTRY_URI", tracking_uri)
    output_root = Path(os.getenv("REPRO_OUTPUT_DIR", "reproduction_packages"))
    # Matches src/train.py's actual output path (DATA_STORAGE_ROOT/train_features.parquet),
    # not a hardcoded local data/processed/ path.
    data_path = os.getenv("REPRO_DATA_PATH", f"{DATA_STORAGE_ROOT}/train_features.parquet")

    mlflow.set_tracking_uri(tracking_uri)
    mlflow.set_registry_uri(registry_uri)
    client = MlflowClient(tracking_uri=tracking_uri, registry_uri=registry_uri)

    package_dir = output_root / run_id
    artifacts_dir = package_dir / "artifacts"
    package_dir.mkdir(parents=True, exist_ok=True)

    print(f"[INFO] Tracking URI: {tracking_uri}")
    print(f"[INFO] Retrieving run: {run_id}")
    run = client.get_run(run_id)

    run_payload = {
        "info": {
            "run_id": run.info.run_id,
            "run_uuid": run.info.run_uuid,
            "experiment_id": run.info.experiment_id,
            "status": run.info.status,
            "artifact_uri": run.info.artifact_uri,
            "start_time": run.info.start_time,
            "end_time": run.info.end_time,
            "lifecycle_stage": run.info.lifecycle_stage,
        },
        "params": dict(run.data.params),
        "metrics": dict(run.data.metrics),
        "tags": dict(run.data.tags),
    }
    _write_json(package_dir / "mlflow_run_metadata.json", run_payload)

    print("[INFO] Downloading all run artifacts...")
    downloaded_root = Path(download_artifacts(run_id=run_id, dst_path=str(artifacts_dir), tracking_uri=tracking_uri, registry_uri=registry_uri))

    selected_features_path = _find_file(downloaded_root, "selected_features.json")
    best_params_path = _find_file(downloaded_root, "best_params.json")
    metrics_path = _find_file(downloaded_root, "train_metrics.json")
    feature_schema_path = _find_file(downloaded_root, "feature_schema.json")

    expected_dataset_sha = run_payload["params"].get("dataset_sha256")
    local_dataset_sha = _fingerprint_current_data(data_path) if expected_dataset_sha else None
    dataset_match = expected_dataset_sha == local_dataset_sha if expected_dataset_sha and local_dataset_sha else None

    manifest = {
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "run_id": run_id,
        "tracking_uri": tracking_uri,
        "registry_uri": registry_uri,
        "package_dir": str(package_dir.resolve()),
        "artifacts_dir": str(downloaded_root.resolve()),
        "run_info": run_payload["info"],
        "params": run_payload["params"],
        "metrics": run_payload["metrics"],
        "tags": run_payload["tags"],
        "detected_files": {
            "selected_features_json": str(selected_features_path) if selected_features_path else None,
            "best_params_json": str(best_params_path) if best_params_path else None,
            "train_metrics_json": str(metrics_path) if metrics_path else None,
            "feature_schema_json": str(feature_schema_path) if feature_schema_path else None,
        },
        "loaded_artifacts": {
            "selected_features": _load_json_if_exists(selected_features_path),
            "best_params": _load_json_if_exists(best_params_path),
            "train_metrics": _load_json_if_exists(metrics_path),
        },
        "dataset_verification": {
            "data_path_checked": data_path,
            "expected_dataset_sha256_from_mlflow": expected_dataset_sha,
            "current_dataset_sha256": local_dataset_sha,
            "match": dataset_match,
        },
    }
    _write_json(package_dir / "reproduction_manifest.json", manifest)
    _write_reproduce_commands(package_dir / "reproduce_commands.sh", manifest)
    print("[OK] Reproduction package created:", package_dir.resolve())
    return package_dir


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Retrieve an MLflow run reproduction package from one run_id.")
    parser.add_argument("run_id", help="MLflow run_id to retrieve")
    args = parser.parse_args()
    retrieve_reproduction_package(args.run_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
