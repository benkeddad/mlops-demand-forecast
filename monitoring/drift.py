"""
Data-drift monitoring for the Rossmann demand forecaster.

Compares the population the current champion model was trained on (the
`train` table) against the population it is currently scoring (the `test`
table), using the *exact same* feature-engineering path as training
(`src.features.build_features`) so the comparison is apples-to-apples
rather than drifting apart from the model's real input schema over time.

Every run:
  - writes a timestamped HTML report to monitoring/reports/ (never overwritten)
  - logs drift metrics + the report as an MLflow run, so drift history is
    queryable over time in the same tracking server as training runs
  - exits non-zero when drift crosses --drift-share-threshold, so this
    script can be dropped into a cron job, CI step, or a Prefect
    deployment as an automated retraining trigger

Usage:
    python monitoring/drift.py
    python monitoring/drift.py --reference-table train --current-table test
    python monitoring/drift.py --drift-share-threshold 0.3 --fail-on-drift
    python monitoring/drift.py --current-limit 5000 --skip-mlflow
"""

import argparse
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Tuple

import pandas as pd
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from evidently.report import Report
from evidently.metric_preset import DataDriftPreset

# Reuse the exact training-time transform (src/features.py) instead of
# re-implementing it here, so drift is measured against real model inputs
# and never silently drifts out of sync with what actually gets trained on.
sys.path.append(str(Path(__file__).resolve().parent.parent))
from src.features import build_features, FEATURE_COLUMNS  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("drift_monitor")

DB_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@localhost:5432/rossmann")
MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
MLFLOW_EXPERIMENT = "data-drift-monitoring"

# Same rename map used in src/features.py, kept local so this script has no
# side effects on the training path if that file evolves independently.
COLUMN_RENAME = {
    "store": "Store",
    "dayofweek": "DayOfWeek",
    "sales": "Sales",
    "customers": "Customers",
    "open": "Open",
    "promo": "Promo",
    "stateholiday": "StateHoliday",
    "schoolholiday": "SchoolHoliday",
    "date": "Date",
    "id": "Id",
}


def load_population(engine: Engine, table: str, limit: Optional[int]) -> pd.DataFrame:
    """Pulls a table from Postgres and runs it through the training-time feature transform."""
    query = f"SELECT * FROM {table}"
    if limit:
        query += f" ORDER BY id DESC LIMIT {limit}"
    df = pd.read_sql(query, engine)
    df = df.rename(columns=COLUMN_RENAME)
    return build_features(df)


def compute_drift(reference_df: pd.DataFrame, current_df: pd.DataFrame) -> Tuple[Report, dict]:
    """Runs Evidently's DataDriftPreset over the shared model-input columns."""
    shared_cols = [c for c in FEATURE_COLUMNS if c in reference_df.columns and c in current_df.columns]
    if not shared_cols:
        raise ValueError(
            f"No shared feature columns between reference and current datasets. "
            f"Expected some of {FEATURE_COLUMNS}."
        )

    report = Report(metrics=[DataDriftPreset()])
    report.run(reference_data=reference_df[shared_cols], current_data=current_df[shared_cols])

    try:
        summary = report.as_dict()["metrics"][0]["result"]
        metrics = {
            "dataset_drift": bool(summary["dataset_drift"]),
            "drift_share": float(summary["share_of_drifted_columns"]),
            "n_drifted_columns": int(summary["number_of_drifted_columns"]),
            "n_columns_checked": int(summary["number_of_columns"]),
        }
    except (KeyError, IndexError) as exc:
        raise RuntimeError(
            "Could not parse Evidently's report output - this usually means an "
            "installed evidently version has a different Report schema than expected. "
            "requirements.txt pins evidently<0.7.0 for this reason; check that pin "
            "hasn't drifted (pun intended)."
        ) from exc

    return report, metrics


def log_to_mlflow(
    metrics: dict,
    reference_table: str,
    current_table: str,
    n_reference: int,
    n_current: int,
    report_path: Path,
) -> None:
    """Logs the drift check as its own MLflow run, separate from training runs."""
    import mlflow  # imported lazily so --skip-mlflow never requires mlflow to be reachable

    mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
    mlflow.set_experiment(MLFLOW_EXPERIMENT)

    run_name = f"drift-check-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"
    with mlflow.start_run(run_name=run_name):
        mlflow.log_param("reference_table", reference_table)
        mlflow.log_param("current_table", current_table)
        mlflow.log_param("n_reference_rows", n_reference)
        mlflow.log_param("n_current_rows", n_current)
        mlflow.log_metrics(
            {
                "drift_share": metrics["drift_share"],
                "n_drifted_columns": metrics["n_drifted_columns"],
                "n_columns_checked": metrics["n_columns_checked"],
                "dataset_drift": int(metrics["dataset_drift"]),
            }
        )
        mlflow.log_artifact(str(report_path), artifact_path="drift_reports")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--reference-table", default="train",
        help="Table representing the population the model was trained on (default: train)",
    )
    parser.add_argument(
        "--current-table", default="test",
        help="Table representing the population currently being scored (default: test)",
    )
    parser.add_argument(
        "--reference-limit", type=int, default=None,
        help="Optionally cap reference rows to the most recent N by id",
    )
    parser.add_argument(
        "--current-limit", type=int, default=None,
        help="Optionally cap current rows to the most recent N by id",
    )
    parser.add_argument(
        "--output-dir", default="monitoring/reports",
        help="Directory for timestamped HTML reports (default: monitoring/reports)",
    )
    parser.add_argument(
        "--drift-share-threshold", type=float, default=0.5,
        help="Fraction of drifted feature columns considered significant (default: 0.5)",
    )
    parser.add_argument(
        "--fail-on-drift", action="store_true",
        help="Exit with status 1 if significant drift is detected (for cron/CI wiring)",
    )
    parser.add_argument(
        "--skip-mlflow", action="store_true",
        help="Skip logging results to MLflow (useful for local/offline runs)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    safe_target = DB_URL.split("@")[-1]  # never log credentials
    logger.info("Connecting to Postgres (%s)...", safe_target)
    engine = create_engine(DB_URL)

    logger.info("Loading reference population from '%s'...", args.reference_table)
    reference_df = load_population(engine, args.reference_table, args.reference_limit)
    logger.info("Loading current population from '%s'...", args.current_table)
    current_df = load_population(engine, args.current_table, args.current_limit)

    if reference_df.empty or current_df.empty:
        logger.error(
            "Reference (%d rows) or current (%d rows) dataset is empty - aborting.",
            len(reference_df), len(current_df),
        )
        sys.exit(2)

    logger.info(
        "Computing drift across up to %d model-input columns (%d reference rows vs %d current rows)...",
        len(FEATURE_COLUMNS), len(reference_df), len(current_df),
    )
    report, metrics = compute_drift(reference_df, current_df)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = output_dir / f"drift_report_{timestamp}.html"
    report.save_html(str(report_path))
    logger.info("Report saved to %s", report_path)

    logger.info(
        "Drift share: %.1f%% (%d/%d columns) | dataset_drift=%s",
        metrics["drift_share"] * 100,
        metrics["n_drifted_columns"],
        metrics["n_columns_checked"],
        metrics["dataset_drift"],
    )

    if not args.skip_mlflow:
        try:
            log_to_mlflow(
                metrics, args.reference_table, args.current_table,
                len(reference_df), len(current_df), report_path,
            )
            logger.info("Drift metrics logged to MLflow experiment '%s'.", MLFLOW_EXPERIMENT)
        except Exception as exc:  # MLflow being unreachable shouldn't kill a monitoring run
            logger.warning("Could not log to MLflow (%s) - continuing without it.", exc)

    significant_drift = metrics["drift_share"] >= args.drift_share_threshold
    if significant_drift:
        logger.warning(
            "SIGNIFICANT DRIFT DETECTED (share=%.2f >= threshold=%.2f).",
            metrics["drift_share"], args.drift_share_threshold,
        )
        if args.fail_on_drift:
            sys.exit(1)
    else:
        logger.info(
            "No significant drift detected (share=%.2f < threshold=%.2f).",
            metrics["drift_share"], args.drift_share_threshold,
        )


if __name__ == "__main__":
    main()
