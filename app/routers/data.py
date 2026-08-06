"""Postgres data observability, exposed over this API for the same reason
as the other routers - no other reachable UI/psql access in a
single-container deployment.
"""
import asyncpg
from fastapi import APIRouter, HTTPException, Query

from app import state

router = APIRouter(prefix="/data", tags=["data"])


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
