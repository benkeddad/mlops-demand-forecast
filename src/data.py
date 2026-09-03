import os
import hashlib
import pandas as pd
from sqlalchemy import create_engine
from sklearn.model_selection import train_test_split

DB_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@localhost:5432/rossmann")
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

def load_data_from_db() -> pd.DataFrame:
    engine = create_engine(DB_URL)
    return pd.read_sql("SELECT * FROM train", engine)

def split_data(df: pd.DataFrame, target_col: str, test_size: float = 0.2, random_state: int = 42):
    y = df[target_col]
    drop_cols = [c for c in (target_col, "entity_id", "event_timestamp") if c in df.columns]
    X = df.drop(columns=drop_cols)
    return train_test_split(X, y, test_size=test_size, random_state=random_state)

def split_data_time_ordered(df: pd.DataFrame, target_col: str, validation_fraction: float = 0.2):
    """Time-aware split (latest rows held out for validation) instead of a
    random one, to avoid the leakage risk a random split has on sequential
    sales data - used only by src/train_optimal.py; split_data() above
    (the fast path, src/train.py) is unchanged.

    Ported from rossmann-forecasting-automated-model-training's split_data,
    adapted to this project's actual processed schema: src/features.py's
    build_features() already breaks a source Date column into Year/Month/Day
    and drops Date entirely, so those three columns are used as the sort
    key here instead of assuming a live Date column exists.
    """
    work = df.copy()
    if {"Year", "Month", "Day"}.issubset(work.columns):
        sort_cols = ["Year", "Month", "Day"] + (["Store"] if "Store" in work.columns else [])
        work = work.sort_values(sort_cols)
    else:
        work = work.sort_index()

    n_val = max(1, int(len(work) * validation_fraction))
    train_df = work.iloc[:-n_val].copy()
    val_df = work.iloc[-n_val:].copy()

    drop_cols = [c for c in (target_col, "entity_id", "event_timestamp", "Date") if c in df.columns]
    X_train = train_df.drop(columns=drop_cols, errors="ignore")
    X_val = val_df.drop(columns=drop_cols, errors="ignore")
    y_train = train_df[target_col]
    y_val = val_df[target_col]
    return X_train, X_val, y_train, y_val

def dataset_fingerprint(df: pd.DataFrame) -> str:
    """Stable SHA-256 fingerprint of a dataframe's content, independent of
    row/column order. Logged as an MLflow param at training time
    (src/train.py) and recomputed against the current data at reproduction
    time (src/reproduce_from_mlflow.py) so a run can be checked against
    whether the data it was trained on has since changed."""
    hashed = pd.util.hash_pandas_object(df.sort_index(axis=1), index=True).values
    return hashlib.sha256(hashed.tobytes()).hexdigest()

if __name__ == "__main__":
    print("Running Data Ingestion from DB...")
    raw_df = load_data_from_db()
    
    s3_path = f"{DATA_STORAGE_ROOT}/clean_data.parquet"
    
    # Write directly to S3 (or local disk when DATA_STORAGE_ROOT isn't s3://)
    raw_df.to_parquet(s3_path, index=False, storage_options=get_storage_options())
    print(f"Saved directly to {s3_path}")