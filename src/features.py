import os
import subprocess
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