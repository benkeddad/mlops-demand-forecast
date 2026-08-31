"""DVC "train_optimal" stage: the full RFECV feature-selection + Optuna
hyperparameter-search training methodology, ported from the standalone
rossmann-forecasting-automated-model-training project. A separate stage and
script from src/train.py's fast fixed-hyperparameter path (unchanged by
this file) - this one is deliberately expensive (RFECV cross-validation
plus dozens of Optuna trials), so it's only ever run on demand via
POST /trigger-optimal-training (app/main.py), never automatically on every
train_changed notification the way the fast path is.

Registers to the same MLflow registered model (Rossmann_XGBoost_Model) as
the fast path, so promote/rollback treat a version produced by either path
identically - only the source experiment and the "training_mode" tag
distinguish which methodology produced a given version.
"""
import json
import logging
import os
import subprocess
import warnings
from datetime import datetime
from pathlib import Path

import mlflow
import mlflow.xgboost
import numpy as np
import optuna
import pandas as pd
import yaml
from sklearn.feature_selection import RFECV
from sklearn.model_selection import TimeSeriesSplit

from data import dataset_fingerprint, split_data_time_ordered
from evaluate import regression_metrics
from model import get_model

# Same two warnings, same reasoning, as src/train.py - this script also
# calls mlflow.log_input()/mlflow.xgboost.log_model() on the same kind of
# S3-sourced, all-integer feature frame, so it hits the identical noise.
warnings.filterwarnings(
    "ignore",
    message=r"Failed to determine whether UCVolumeDatasetSource.*",
    category=UserWarning,
)
warnings.filterwarnings(
    "ignore",
    message=r"Hint: Inferred schema contains integer column\(s\).*",
    category=UserWarning,
)

S3_ENDPOINT = os.getenv("MLFLOW_S3_ENDPOINT_URL", "http://localhost:4566")
S3_BUCKET = os.getenv("DVC_S3_BUCKET", "rossmann-mlops-dvc-store")
DATA_STORAGE_ROOT = os.getenv("DATA_STORAGE_ROOT", f"s3://{S3_BUCKET}/processed-data")


def get_storage_options():
    if not DATA_STORAGE_ROOT.startswith("s3://"):
        return {}
    return {
        "key": os.getenv("AWS_ACCESS_KEY_ID", "test"),
        "secret": os.getenv("AWS_SECRET_ACCESS_KEY", "test"),
        "client_kwargs": {"endpoint_url": S3_ENDPOINT} if S3_ENDPOINT else {},
    }


LOG_DIR = Path("logs")
LOG_DIR.mkdir(exist_ok=True)
LOG_FILE = LOG_DIR / f"train_optimal_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler()],
)
logger = logging.getLogger("rossmann_optimal_training")

_mlflow_uri = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
mlflow.set_tracking_uri(_mlflow_uri)
mlflow.set_registry_uri(os.getenv("MLFLOW_REGISTRY_URI", _mlflow_uri))

REGISTERED_MODEL_NAME = "Rossmann_XGBoost_Model"
EXPERIMENT_NAME = os.getenv("MLFLOW_OPTIMAL_EXPERIMENT_NAME", "Rossmann_Sales_Forecasting_Optimal")
RANDOM_STATE = int(os.getenv("RANDOM_STATE", "42"))

# Defaults deliberately NOT baked into the shared get_model() in model.py -
# that function is also used by the fast path, and adding these there would
# silently change the fast path's model too. Kept local to this file instead.
_OPTIMAL_MODEL_DEFAULTS = {"tree_method": "hist", "n_jobs": -1, "eval_metric": "rmse"}


def _load_params():
    params_path = Path("params.yaml")
    if params_path.exists():
        return yaml.safe_load(params_path.read_text(encoding="utf-8")) or {}
    return {}


_PARAMS = _load_params().get("train_optimal", {})
N_TRIALS = int(os.getenv("OPTUNA_N_TRIALS", _PARAMS.get("optuna_n_trials", 40)))
MIN_FEATURES_TO_SELECT = int(os.getenv("MIN_FEATURES_TO_SELECT", _PARAMS.get("min_features_to_select", 8)))
VALIDATION_FRACTION = float(os.getenv("VALIDATION_FRACTION", _PARAMS.get("validation_fraction", 0.2)))


def _git_commit():
    """Best-effort commit hash - falls back to "unknown" rather than
    failing the run if .git isn't present. Same helper as src/train.py;
    duplicated rather than imported since both are meant to run as fully
    standalone DVC-stage scripts (see src/data.py, src/features.py for the
    same self-containment convention with get_storage_options())."""
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return "unknown"


def json_safe(obj):
    """Convert NumPy/Pandas objects into JSON-serializable Python objects."""
    if isinstance(obj, dict):
        return {str(k): json_safe(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [json_safe(v) for v in obj]
    if isinstance(obj, np.integer):
        return int(obj)
    if isinstance(obj, np.floating):
        return float(obj)
    if isinstance(obj, np.ndarray):
        return obj.tolist()
    if isinstance(obj, pd.Timestamp):
        return obj.isoformat()
    return obj


def _select_features_rfe(X_train, y_train, min_features=8):
    logger.info("Starting RFECV feature selection on %s candidate features...", X_train.shape[1])
    min_features = min(min_features, X_train.shape[1])
    estimator = get_model(
        n_estimators=250, max_depth=4, learning_rate=0.05, subsample=0.9, colsample_bytree=0.9,
        **_OPTIMAL_MODEL_DEFAULTS,
    )
    selector = RFECV(
        estimator=estimator,
        step=max(1, X_train.shape[1] // 10),
        min_features_to_select=min_features,
        cv=TimeSeriesSplit(n_splits=3),
        scoring="neg_root_mean_squared_error",
        n_jobs=-1,
    )
    selector.fit(X_train, y_train)
    selected = [str(col) for col in X_train.columns[selector.support_].tolist()]
    ranking = {str(col): int(rank) for col, rank in zip(X_train.columns, selector.ranking_)}
    logger.info("RFECV completed. Selected %s features.", len(selected))
    return selected, ranking


def _objective(trial, X_train, y_train, X_val, y_val):
    params = {
        "n_estimators": trial.suggest_int("n_estimators", 300, 1500, step=100),
        "max_depth": trial.suggest_int("max_depth", 3, 12),
        "learning_rate": trial.suggest_float("learning_rate", 0.005, 0.2, log=True),
        "subsample": trial.suggest_float("subsample", 0.6, 1.0),
        "colsample_bytree": trial.suggest_float("colsample_bytree", 0.6, 1.0),
        "min_child_weight": trial.suggest_float("min_child_weight", 1.0, 15.0),
        "reg_alpha": trial.suggest_float("reg_alpha", 1e-8, 10.0, log=True),
        "reg_lambda": trial.suggest_float("reg_lambda", 1e-8, 50.0, log=True),
        "gamma": trial.suggest_float("gamma", 0.0, 10.0),
    }
    with mlflow.start_run(nested=True, run_name=f"optuna_trial_{trial.number}"):
        mlflow.log_params(json_safe(params))
        model = get_model(**params, **_OPTIMAL_MODEL_DEFAULTS)
        model.fit(X_train, y_train, eval_set=[(X_val, y_val)], verbose=False)
        metrics = regression_metrics(y_val.values, model.predict(X_val))
        mlflow.log_metrics({f"trial_{k}": v for k, v in json_safe(metrics).items()})
        return metrics["rmspe"]


def _log_trial_progress(study, trial):
    logger.info("Optuna trial %s finished | value=%s | best_value=%s", trial.number, trial.value, study.best_value)


def run_training_optimal(processed_data_s3_path: str):
    logger.info("Loading processed features from %s", processed_data_s3_path)
    processed_df = pd.read_parquet(processed_data_s3_path, storage_options=get_storage_options())
    X_train, X_val, y_train, y_val = split_data_time_ordered(
        processed_df, target_col="Sales", validation_fraction=VALIDATION_FRACTION
    )

    X_train = X_train.select_dtypes(include=[np.number]).replace([np.inf, -np.inf], np.nan).fillna(0)
    X_val = X_val[X_train.columns].replace([np.inf, -np.inf], np.nan).fillna(0)
    logger.info(
        "Training rows=%s, validation rows=%s, numeric features=%s",
        X_train.shape[0], X_val.shape[0], X_train.shape[1],
    )

    mlflow.set_experiment(EXPERIMENT_NAME)
    with mlflow.start_run(run_name="rossmann_xgboost_automl_rfe") as run:
        dataset = mlflow.data.from_pandas(processed_df, source=processed_data_s3_path, name="train_features")
        mlflow.log_input(dataset, context="training")
        mlflow.set_tags({
            "git_commit": _git_commit(),
            "feature_selection": "RFECV_XGBoost_TimeSeriesSplit",
            "automl": "Optuna_TPE",
            "reproducibility": "mlflow_git_dvc_dataset_hash",
            "training_mode": "optimal",
        })
        mlflow.log_param("dataset_sha256", dataset_fingerprint(processed_df))
        # Unlike src/train.py's "random_holdout", this genuinely is
        # time-ordered - see split_data_time_ordered() in src/data.py.
        mlflow.log_param("validation_strategy", "time_ordered_holdout")
        mlflow.log_param("optuna_n_trials", N_TRIALS)

        selected_features, ranking = _select_features_rfe(X_train, y_train, min_features=MIN_FEATURES_TO_SELECT)
        Path("models").mkdir(exist_ok=True)
        Path("models/selected_features.json").write_text(json.dumps(json_safe(selected_features), indent=2), encoding="utf-8")
        Path("models/feature_selection_report.json").write_text(json.dumps(json_safe({"ranking": ranking}), indent=2), encoding="utf-8")
        mlflow.log_artifact("models/selected_features.json", artifact_path="feature_selection")
        mlflow.log_artifact("models/feature_selection_report.json", artifact_path="feature_selection")
        mlflow.log_param("n_selected_features", len(selected_features))

        X_train_sel = X_train[selected_features]
        X_val_sel = X_val[selected_features]

        logger.info("Starting Optuna tuning with %s trials...", N_TRIALS)
        study = optuna.create_study(
            direction="minimize",
            sampler=optuna.samplers.TPESampler(seed=RANDOM_STATE, multivariate=True),
            pruner=optuna.pruners.MedianPruner(n_warmup_steps=5),
            study_name="rossmann_xgb_rmspe",
        )
        study.optimize(
            lambda t: _objective(t, X_train_sel, y_train, X_val_sel, y_val),
            n_trials=N_TRIALS,
            callbacks=[_log_trial_progress],
            show_progress_bar=True,
        )

        best_params = json_safe(study.best_params)
        Path("models/best_params.json").write_text(json.dumps(best_params, indent=2), encoding="utf-8")
        mlflow.log_artifact("models/best_params.json", artifact_path="automl")
        mlflow.log_params({f"best_{k}": v for k, v in best_params.items()})
        mlflow.log_metric("best_optuna_rmspe", float(study.best_value))

        logger.info("Training final model with best params...")
        final_model = get_model(**best_params, **_OPTIMAL_MODEL_DEFAULTS)
        final_model.fit(X_train_sel, y_train, eval_set=[(X_val_sel, y_val)], verbose=50)
        predictions = final_model.predict(X_val_sel)
        final_metrics = json_safe(regression_metrics(y_val.values, predictions))
        mlflow.log_metrics({f"val_{k}": v for k, v in final_metrics.items()})

        # Distinct filename from src/train.py's metrics/train_metrics.json -
        # the two paths' outputs never collide, and pipelines/reproduction_
        # pipeline.py's execute_retrain=true path (which targets the "train"
        # stage specifically) is unaffected by this file's existence.
        metrics_path = Path("metrics/train_optimal_metrics.json")
        metrics_path.parent.mkdir(parents=True, exist_ok=True)
        metrics_path.write_text(json.dumps(final_metrics, indent=2), encoding="utf-8")
        mlflow.log_artifact(str(metrics_path), artifact_path="metrics")
        mlflow.log_artifact(str(LOG_FILE), artifact_path="logs")

        signature = mlflow.models.infer_signature(X_train_sel.head(20), final_model.predict(X_train_sel.head(20)))
        mlflow.xgboost.log_model(
            xgb_model=final_model,
            name="xgboost_model",
            registered_model_name=REGISTERED_MODEL_NAME,
            input_example=X_train_sel.head(5),
            signature=signature,
            # Matches src/train.py: makes the current UBJSON-by-default
            # save format explicit instead of implicit; doesn't change what
            # actually gets saved.
            model_format="ubj",
        )
        logger.info(
            "Optimal training completed. Final RMSPE=%.6f | run_id=%s",
            final_metrics["rmspe"], run.info.run_id,
        )
        return final_metrics


if __name__ == "__main__":
    s3_path = f"{DATA_STORAGE_ROOT}/train_features.parquet"
    run_training_optimal(s3_path)
