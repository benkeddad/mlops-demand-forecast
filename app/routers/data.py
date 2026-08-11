"""Postgres data observability, exposed over this API for the same reason
as the other routers - no other reachable UI/psql access in a
single-container deployment.
"""
import io
import logging

import asyncpg
import pandas as pd
from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile

from app import state
from app.auth import require_api_key

logger = logging.getLogger("sales_api")

router = APIRouter(prefix="/data", tags=["data"])

# Column sets mirror db/init.sql exactly (minus the SERIAL `id` and, for
# `test`, `predicted_sales` - both are left for Postgres/the prediction loop
# to fill in, never for an uploaded CSV to set directly).
_TRAIN_COLUMNS = [
    "store", "dayofweek", "date", "sales", "customers", "open", "promo",
    "stateholiday", "schoolholiday",
]
_TEST_COLUMNS = [
    "store", "dayofweek", "date", "open", "promo", "stateholiday", "schoolholiday",
]

# Kaggle's Rossmann test.csv famously has a handful of blank `Open` values -
# defaulting a missing flag to "store was open" is the standard convention
# for this dataset, so uploads follow the same rule rather than silently
# dropping those rows.
_INT_COLUMN_DEFAULTS = {
    "store": 0, "dayofweek": 0, "sales": 0, "customers": 0,
    "open": 1, "promo": 0, "schoolholiday": 0,
}


async def _load_csv_into_table(file: UploadFile, table: str, required_columns: list) -> dict:
    """Normalizes an uploaded CSV to db/init.sql's schema for `table` and
    bulk-loads it via COPY. Reuses the same lowercase-columns / dayfirst-date
    convention as db/seed_db.py's initial load, so a manual upload lines up
    with what a fresh seed produces.

    Deliberately uses asyncpg's COPY (not pandas.to_sql, which needs a
    blocking sync engine) so this stays a well-behaved async route, and so
    Postgres' own triggers fire exactly as they do for any other write:
    notify_train_change() once per statement, notify_test_insert() once per
    row - the existing train-changed/test-inserted reactive pipeline (see
    app/main.py) picks up an uploaded batch the same way it picks up any
    other insert, no extra wiring needed here.
    """
    if not file.filename or not file.filename.lower().endswith(".csv"):
        raise HTTPException(status_code=400, detail="Only .csv files are accepted.")

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Uploaded file is empty.")

    try:
        df = pd.read_csv(io.BytesIO(raw), low_memory=False)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not parse CSV: {exc}")

    df.columns = df.columns.str.strip().str.lower()

    missing = [c for c in required_columns if c not in df.columns]
    if missing:
        raise HTTPException(
            status_code=400,
            detail=(
                f"CSV is missing required column(s) for the '{table}' table: "
                f"{', '.join(missing)}"
            ),
        )

    df["date"] = pd.to_datetime(df["date"], dayfirst=True, errors="coerce")
    rows_before = len(df)
    df = df[df["date"].notna()]
    rows_skipped_bad_date = rows_before - len(df)

    for col, default in _INT_COLUMN_DEFAULTS.items():
        if col in required_columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(default).astype(int)

    if "stateholiday" in required_columns:
        df["stateholiday"] = df["stateholiday"].fillna("0").astype(str).str.strip()

    df = df[required_columns].copy()
    df["date"] = df["date"].dt.date  # asyncpg wants plain date objects, not Timestamps

    records = list(df.itertuples(index=False, name=None))
    if not records:
        raise HTTPException(status_code=400, detail="No valid rows to insert after cleaning.")

    conn = await asyncpg.connect(state.DB_URL)
    try:
        await conn.copy_records_to_table(table, records=records, columns=required_columns)
    finally:
        await conn.close()

    logger.info(f"Uploaded {len(records)} rows into '{table}' from '{file.filename}'.")
    return {
        "status": "ok",
        "table": table,
        "filename": file.filename,
        "rows_inserted": len(records),
        "rows_skipped_bad_date": rows_skipped_bad_date,
    }


@router.post(
    "/upload/train",
    summary="Upload a CSV of historical sales and append it to the train table",
    dependencies=[Depends(require_api_key)],
)
async def upload_train_csv(file: UploadFile = File(..., description="CSV with Store, DayOfWeek, Date, Sales, Customers, Open, Promo, StateHoliday, SchoolHoliday columns")):
    result = await _load_csv_into_table(file, "train", _TRAIN_COLUMNS)
    result["note"] = "A batch insert fires exactly one train_changed notification, which triggers a Prefect training run."
    return result


@router.post(
    "/upload/test",
    summary="Upload a CSV of rows to forecast and append it to the test table",
    dependencies=[Depends(require_api_key)],
)
async def upload_test_csv(file: UploadFile = File(..., description="CSV with Store, DayOfWeek, Date, Open, Promo, StateHoliday, SchoolHoliday columns (an Id/Sales/Customers column, if present, is ignored)")):
    result = await _load_csv_into_table(file, "test", _TEST_COLUMNS)
    result["note"] = "Each inserted row fires test_inserted, which triggers batch prediction to fill in predicted_sales."
    return result


@router.get("/stats", summary="Row counts and prediction coverage")
async def data_stats():
    conn = await asyncpg.connect(state.DB_URL)
    try:
        train_count = await conn.fetchval("SELECT COUNT(*) FROM train")
        test_count = await conn.fetchval("SELECT COUNT(*) FROM test")
        unpredicted = await conn.fetchval(
            "SELECT COUNT(*) FROM test WHERE predicted_sales IS NULL"
        )
        return {
            "train_rows": train_count,
            "test_rows": test_count,
            "unpredicted_rows": unpredicted,
            "predicted_rows": test_count - unpredicted,
        }
    finally:
        await conn.close()


@router.get("/predictions", summary="Paginated recent predictions from the test table")
async def list_predictions(limit: int = Query(50, le=500), offset: int = 0):
    conn = await asyncpg.connect(state.DB_URL)
    try:
        rows = await conn.fetch(
            """
            SELECT id, store, date, predicted_sales FROM test
            WHERE predicted_sales IS NOT NULL
            ORDER BY id
            LIMIT $1 OFFSET $2
            """,
            limit,
            offset,
        )
        return [dict(r) for r in rows]
    finally:
        await conn.close()


@router.get("/predictions/{store_id}", summary="All predictions for a single store")
async def store_predictions(store_id: int):
    conn = await asyncpg.connect(state.DB_URL)
    try:
        rows = await conn.fetch(
            "SELECT id, date, predicted_sales FROM test WHERE store = $1 ORDER BY date",
            store_id,
        )
        if not rows:
            raise HTTPException(status_code=404, detail=f"No test rows found for store {store_id}.")
        return [dict(r) for r in rows]
    finally:
        await conn.close()
