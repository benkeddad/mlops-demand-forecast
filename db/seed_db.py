import os
import time
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.exc import OperationalError

PROJECT_ROOT = Path(__file__).resolve().parent.parent
TRAIN_CSV_PATH = PROJECT_ROOT / "data" / "raw" / "train.csv"
TEST_CSV_PATH = PROJECT_ROOT / "data" / "test.csv"
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@127.0.0.1:5432/rossmann")


def _read_and_normalize_csv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, low_memory=False)
    df.columns = df.columns.str.lower()
    if "date" in df.columns:
        df["date"] = pd.to_datetime(df["date"], dayfirst=True)
    return df


def _connect_with_retry(engine, attempts: int = 5, delay_seconds: float = 2.0):
    # A raw TCP port being open (e.g. a prior readiness check) doesn't
    # guarantee the very next real connection succeeds - simple L4 proxies
    # in front of Postgres (e.g. k3s's ServiceLB) can drop/reset an
    # individual connection attempt without the backend being unhealthy.
    # Retry the real connection itself rather than trusting one attempt.
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return engine.connect()
        except OperationalError as exc:
            last_error = exc
            if attempt < attempts:
                print(f"Database connection attempt {attempt}/{attempts} failed, retrying...")
                time.sleep(delay_seconds)
    raise last_error


def seed_database(database_url: str = DATABASE_URL) -> None:
    if not TRAIN_CSV_PATH.exists():
        raise FileNotFoundError(f"Train CSV not found: {TRAIN_CSV_PATH}")
    if not TEST_CSV_PATH.exists():
        raise FileNotFoundError(f"Test CSV not found: {TEST_CSV_PATH}")

    engine = create_engine(database_url)

    with _connect_with_retry(engine) as conn:
        train_count = conn.execute(text("SELECT COUNT(*) FROM train")).scalar()

    if train_count > 0:
        print(f"Database already contains {train_count} records in train. Skipping data seed.")
    else:
        print(f"Reading train CSV from {TRAIN_CSV_PATH} ...")
        train_df = _read_and_normalize_csv(TRAIN_CSV_PATH)
        print("Uploading records to PostgreSQL (train table)...")
        train_df.to_sql("train", engine, if_exists="append", index=False, chunksize=10000)
        print(f"Done! Successfully loaded {len(train_df)} rows to the train table.")

    with _connect_with_retry(engine) as conn:
        test_count = conn.execute(text("SELECT COUNT(*) FROM test")).scalar()

    if test_count > 0:
        print(f"Database already contains {test_count} records in test. Skipping data seed.")
    else:
        print(f"Reading test CSV from {TEST_CSV_PATH} ...")
        test_df = _read_and_normalize_csv(TEST_CSV_PATH)
        print("Uploading records to PostgreSQL (test table)...")
        test_df.to_sql("test", engine, if_exists="append", index=False, chunksize=10000)
        print(f"Done! Successfully loaded {len(test_df)} rows to the test table.")


if __name__ == "__main__":
    seed_database()