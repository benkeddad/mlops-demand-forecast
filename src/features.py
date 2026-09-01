import os
import subprocess

import numpy as np
import pandas as pd

FEATURE_COLUMNS = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
_HOLIDAY_MAP = {"0": 0, "a": 1, "b": 2, "c": 3}

S3_ENDPOINT = os.getenv("MLFLOW_S3_ENDPOINT_URL", "http://localhost:4566")
S3_BUCKET = os.getenv("DVC_S3_BUCKET", "rossmann-mlops-dvc-store")
# Overridable so this same script can target a plain local directory instead
# of S3 (e.g. Hugging Face Spaces, which has no Docker-in-Docker access for
# LocalStack) - defaults to today's S3 path, unchanged for k3s/Compose.
DATA_STORAGE_ROOT = os.getenv("DATA_STORAGE_ROOT", f"s3://{S3_BUCKET}/processed-data")

_COLUMN_CANONICAL_NAMES = {
    "store": "Store",
    "dayofweek": "DayOfWeek",
    "promo": "Promo",
    "stateholiday": "StateHoliday",
    "schoolholiday": "SchoolHoliday",
    "sales": "Sales",
    "date": "Date",
    "customers": "Customers",
    "open": "Open",
    "id": "Id",
}

def get_storage_options():
    if not DATA_STORAGE_ROOT.startswith("s3://"):
        return {}
    return {
        "key": os.getenv("AWS_ACCESS_KEY_ID", "test"),
        "secret": os.getenv("AWS_SECRET_ACCESS_KEY", "test"),
        "client_kwargs": {"endpoint_url": S3_ENDPOINT} if S3_ENDPOINT else {}
    }


def _canonicalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    """Normalize casing from DB-loaded lowercase columns to training schema names."""
    df = df.copy()
    rename_map = {}
    for col in df.columns:
        canonical = _COLUMN_CANONICAL_NAMES.get(str(col).strip().lower())
        if canonical and canonical not in df.columns:
            rename_map[col] = canonical
    if rename_map:
        df.rename(columns=rename_map, inplace=True)
    return df

def build_features(df: pd.DataFrame) -> pd.DataFrame:
    df = _canonicalize_columns(df)
    if "Date" in df.columns:
        dt = pd.to_datetime(df["Date"])
        # .dt.year/.month/.day are int32 by default, but predict_initial.py's
        # blanket `.astype(int)` on serving input produces int64 - mismatched
        # dtypes are invisible until something enforces a schema. Forcing
        # int64 here (matching every other integer column already produced
        # from Store/DayOfWeek/etc.) keeps train-time and serving-time
        # dtypes identical so mlflow's logged model signature (added in
        # src/train.py) doesn't reject real inference input.
        df["Year"]  = dt.dt.year.astype("int64")
        df["Month"] = dt.dt.month.astype("int64")
        df["Day"]   = dt.dt.day.astype("int64")
        df.drop(columns=["Date"], inplace=True)

    if "StateHoliday" in df.columns:
        df["StateHoliday"] = (
            df["StateHoliday"].astype(str).str.strip()
            .map(_HOLIDAY_MAP).fillna(0).astype(int)
        )

    drop_cols = [c for c in ("Customers", "Open", "Id") if c in df.columns]
    if drop_cols:
        df.drop(columns=drop_cols, inplace=True)

    df.fillna(0, inplace=True)
    return df


# Column-name prefixes unique to build_features_rich()'s output - a model
# needing any of these needs a store's own recent Sales history to serve,
# not just the row's own fields. Used by src/serving_features.py to decide
# whether a prediction batch needs a historical lookback query at all.
RICH_HISTORY_DEPENDENT_PREFIXES = ("SalesLag", "SalesRollingMean", "SalesRollingStd", "SalesMomentum", "StoreExpanding")


def _safe_divide(a, b):
    return np.where(np.asarray(b) == 0, 0, np.asarray(a) / np.asarray(b))


def build_features_rich(df: pd.DataFrame) -> pd.DataFrame:
    """Full feature set for src/train_optimal.py's RFECV+Optuna path -
    everything build_features() has, plus calendar/cyclical features and
    leakage-safe lag/rolling/expanding statistics on each store's own past
    Sales. Ported from rossmann-forecasting-automated-model-training's
    build_features(), which had no lean/rich split - adapted here to this
    project's column-canonicalization convention (_canonicalize_columns())
    and to work identically whether called on a full historical training
    batch or on a (history + new prediction rows) batch at serving time
    (see src/serving_features.py) - the shift()/rolling() calls only ever
    look backward, so newly-appended rows with no real Sales yet still get
    correct lag/rolling values as long as they're sorted in after real
    history for their store.

    Unlike build_features(), this does NOT drop Date - it's needed to sort
    before computing the lag/rolling window features, and at serving time
    to merge the new rows' computed features back out of the combined
    frame (see compute_prediction_features() in src/serving_features.py).
    It's harmless to leave in for training: the existing
    X.select_dtypes(include=[np.number]) step in both src/train.py and
    src/train_optimal.py already excludes non-numeric columns before they
    ever reach RFECV/the model, exactly as it does in the source project.
    """
    df = _canonicalize_columns(df)

    if "Date" in df.columns:
        df["Date"] = pd.to_datetime(df["Date"])
        df = df.sort_values(["Store", "Date"] if "Store" in df.columns else ["Date"])
        df["Year"] = df["Date"].dt.year.astype("int64")
        df["Month"] = df["Date"].dt.month.astype("int64")
        df["Day"] = df["Date"].dt.day.astype("int64")
        df["WeekOfYear"] = df["Date"].dt.isocalendar().week.astype("int64")
        df["Quarter"] = df["Date"].dt.quarter.astype("int64")
        df["IsMonthStart"] = df["Date"].dt.is_month_start.astype("int64")
        df["IsMonthEnd"] = df["Date"].dt.is_month_end.astype("int64")
        df["DayOfYear"] = df["Date"].dt.dayofyear.astype("int64")
        df["MonthSin"] = np.sin(2 * np.pi * df["Month"] / 12)
        df["MonthCos"] = np.cos(2 * np.pi * df["Month"] / 12)
        if "DayOfWeek" in df.columns:
            df["DayOfWeekSin"] = np.sin(2 * np.pi * df["DayOfWeek"] / 7)
            df["DayOfWeekCos"] = np.cos(2 * np.pi * df["DayOfWeek"] / 7)

    if "StateHoliday" in df.columns:
        df["StateHoliday"] = (
            df["StateHoliday"].astype(str).str.strip()
            .map(_HOLIDAY_MAP).fillna(0).astype(int)
        )

    for col in ["Store", "DayOfWeek", "Promo", "SchoolHoliday", "Open"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)

    # Past-only target-derived statistics. shift() prevents same-day target
    # leakage - a row's own Sales never contributes to its own features.
    if {"Store", "Sales"}.issubset(df.columns):
        grouped = df.groupby("Store", group_keys=False)["Sales"]
        for lag in [1, 7, 14, 28]:
            df[f"SalesLag{lag}"] = grouped.shift(lag)

        shifted = grouped.shift(1)
        for window in [7, 14, 28]:
            df[f"SalesRollingMean{window}"] = shifted.groupby(df["Store"]).rolling(window, min_periods=2).mean().reset_index(level=0, drop=True)
            df[f"SalesRollingStd{window}"] = shifted.groupby(df["Store"]).rolling(window, min_periods=2).std().reset_index(level=0, drop=True)

        df["SalesMomentum7_28"] = _safe_divide(df["SalesRollingMean7"], df["SalesRollingMean28"])
        expanding = grouped.shift(1).groupby(df["Store"]).expanding(min_periods=5)
        df["StoreExpandingMeanSales"] = expanding.mean().reset_index(level=0, drop=True)
        df["StoreExpandingMedianSales"] = expanding.median().reset_index(level=0, drop=True)

    # Customers is removed because it is commonly not known at forecast time.
    df = df.drop(columns=[c for c in ["Customers", "Id"] if c in df.columns], errors="ignore")
    df = df.replace([np.inf, -np.inf], np.nan)
    # Sales and Date are left un-filled: Sales is genuinely unknown for
    # prediction rows (filling it with 0 would look like an actual zero-
    # sales day to anything reading it later), and Date is needed intact
    # for the serving-time merge described above. Every engineered feature
    # column is filled, matching build_features()'s existing behavior.
    fill_cols = [c for c in df.columns if c not in ("Sales", "Date")]
    df[fill_cols] = df[fill_cols].fillna(0)
    return df

if __name__ == "__main__":
    print("Running Feature Engineering...")
    input_s3_path = f"{DATA_STORAGE_ROOT}/clean_data.parquet"
    output_s3_path = f"{DATA_STORAGE_ROOT}/train_features.parquet"

    # Read input direct from S3
    clean_df = pd.read_parquet(input_s3_path, storage_options=get_storage_options())

    processed_df = build_features(clean_df)
    if "Store" not in processed_df.columns:
        raise ValueError(
            "Missing required column 'Store' after feature preprocessing. "
            f"Available columns: {sorted(processed_df.columns.tolist())}"
        )

    processed_df["entity_id"] = processed_df["Store"].astype(int)
    processed_df["event_timestamp"] = pd.Timestamp.now()

    # Write output direct to S3
    processed_df.to_parquet(output_s3_path, index=False, storage_options=get_storage_options())
    print(f"Saved directly to {output_s3_path}")

    # Sync Feast
    print("Syncing features to Redis via Feast...")
    subprocess.run(["feast", "apply"], cwd="feature_repo", check=True)
    subprocess.run(
        ["feast", "materialize", "2010-01-01T00:00:00", "2030-12-31T23:59:59"],
        cwd="feature_repo",
        check=True
    )