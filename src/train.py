import json
import os
import subprocess
import warnings
from pathlib import Path

import pandas as pd
import mlflow
import mlflow.xgboost
from data import split_data, dataset_fingerprint
from model import get_model
from evaluate import calculate_rmspe

# mlflow.log_input() below always probes several dataset-source resolvers,
# including a Databricks Unity Catalog Volume one - on any non-Databricks
# source (this project's is s3://...) that resolver reports it can't help,
# and mlflow surfaces that as a UserWarning. It's mlflow's own internal
# resolver-selection mechanics, not something this project's code can
# address - there's no s3-specific opt-out, and the alternative is dropping
# mlflow.log_input()'s dataset-lineage tracking entirely, which is worth
# more than the warning is worth losing.
warnings.filterwarnings(
    "ignore",
    message=r"Failed to determine whether UCVolumeDatasetSource.*",
    category=UserWarning,
)
# Same reasoning for the integer-column schema-inference hint below: it's a
# real, valid caveat in general (integer columns can't natively represent
# missing values in schema-enforced inference), but this project's actual
# inference path (src/predict_initial.py) already coerces every one of these
# columns through `.fillna(0).astype(int)` before calling model.predict() -
# the scenario this warning exists to flag is already handled upstream of
# where it would matter.
warnings.filterwarnings(
    "ignore",
    message=r"Hint: Inferred schema contains integer column\(s\).*",
    category=UserWarning,
)

S3_ENDPOINT = os.getenv("MLFLOW_S3_ENDPOINT_URL", "http://localhost:4566")
S3_BUCKET = os.getenv("DVC_S3_BUCKET", "rossmann-mlops-dvc-store")
# Overridable so this same script can target a plain local directory instead
# of S3 (e.g. Hugging Face Spaces, which has no Docker-in-Docker access for
# LocalStack) - defaults to today's S3 path, unchanged for k3s/Compose.
DATA_STORAGE_ROOT = os.getenv("DATA_STORAGE_ROOT", f"s3://{S3_BUCKET}/processed-data")

def get_storage_options():
    if not DATA_STORAGE_ROOT.startswith("s3://"):
        return {}
    return {
        "key": os.getenv("AWS_ACCESS_KEY_ID", "test"),
        "secret": os.getenv("AWS_SECRET_ACCESS_KEY", "test"),
        "client_kwargs": {"endpoint_url": S3_ENDPOINT} if S3_ENDPOINT else {}
    }

_mlflow_uri = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
mlflow.set_tracking_uri(_mlflow_uri)
mlflow.set_registry_uri(_mlflow_uri)

REGISTERED_MODEL_NAME = "Rossmann_XGBoost_Model"

def _git_commit():
    """Best-effort commit hash for reproducibility tagging - falls back to
    "unknown" rather than failing the run if .git isn't present (e.g. some
    container builds don't COPY it in)."""
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return "unknown"

def run_training(processed_data_s3_path: str):
    print(f"Loading processed features directly from {processed_data_s3_path}...")
    processed_df = pd.read_parquet(processed_data_s3_path, storage_options=get_storage_options())

    X_train, X_val, y_train, y_val = split_data(processed_df, target_col='Sales')
    # Renamed from "Rossmann_Sales_Forecasting" when the MLflow server's
    # --default-artifact-root moved to S3. MLflow records each experiment's
    # artifact_location at creation time and never changes it afterwards, so
    # the old experiment would keep writing to its original local PVC path
    # forever even after the server-wide default changed. A fresh experiment
    # name is required to actually pick up the new S3-backed root; the old
    # experiment (and its run/model history) is untouched and still browsable.
    mlflow.set_experiment("Rossmann_Sales_Forecasting_v2")

    with mlflow.start_run():
        # Store metadata reference to the exact parquet data used for training
        dataset = mlflow.data.from_pandas(processed_df, source=processed_data_s3_path)
        mlflow.log_input(dataset, context="training")

        # Reproducibility provenance: which code and which exact data
        # produced this run. Consumed by src/reproduce_from_mlflow.py to
        # check out the same commit and verify the data hasn't drifted.
        mlflow.set_tag("git_commit", _git_commit())
        mlflow.log_param("dataset_sha256", dataset_fingerprint(processed_df))
        # Reflects split_data()'s actual current strategy (a random holdout,
        # not a time-ordered one) - keep this in sync if that ever changes.
        mlflow.log_param("validation_strategy", "random_holdout")

        model = get_model(n_estimators=150, max_depth=8)
        model.fit(X_train, y_train)

        predictions = model.predict(X_val)
        rmspe_score = calculate_rmspe(y_val.values, predictions)

        mlflow.log_param("model_type", "XGBRegressor")
        mlflow.log_param("n_estimators", 150)
        mlflow.log_param("max_depth", 8)
        mlflow.log_metric("val_rmspe", rmspe_score)

        # Also written locally (not just to MLflow) so
        # pipelines/reproduction_pipeline.py can diff a retrained run's
        # metrics against the original's without needing a second MLflow
        # round-trip. Declared as a DVC metrics output below (dvc.yaml).
        metrics_path = Path("metrics/train_metrics.json")
        metrics_path.parent.mkdir(parents=True, exist_ok=True)
        metrics_path.write_text(json.dumps({"val_rmspe": rmspe_score}, indent=2), encoding="utf-8")

        mlflow.xgboost.log_model(
            xgb_model=model,
            name="xgboost_model",
            registered_model_name=REGISTERED_MODEL_NAME,
            signature=mlflow.models.infer_signature(X_val, predictions),
            input_example=X_val.head(5),
            # Silences the "saving in UBJSON by default" notice by making
            # that same current default explicit instead of implicit -
            # doesn't change what actually gets saved.
            model_format="ubj",
        )
        print(f"Training completed. RMSPE: {rmspe_score:.4f}")


if __name__ == "__main__":
    s3_path = f"{DATA_STORAGE_ROOT}/train_features.parquet"
    run_training(s3_path)