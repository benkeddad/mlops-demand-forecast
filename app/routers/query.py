"""A read-only SQL console over the Rossmann Postgres database, exposed for
the same reason as app/routers/data.py - no other reachable psql/UI access
in a single-container deployment. Two endpoints: /query/run returns JSON,
/query/download streams the same result as a CSV file.

Deliberately SELECT-only: this sits on the same unauthenticated path as the
other observability endpoints (browsing state is meant to stay open - see
app/auth.py), so letting arbitrary DDL/DML through here would turn a
read-only dashboard into an unauthenticated database console. Writes go
through the purpose-built /data/upload/* endpoints instead, which stay
behind require_api_key.
"""
import csv
import io
import logging
import re

import asyncpg
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

from app import state

logger = logging.getLogger("sales_api")

router = APIRouter(prefix="/query", tags=["query"])

# Hard ceiling on rows returned/downloaded in one call - `train` alone is
# 1M+ rows, and this console has no pagination, so an unbounded query must
# never be able to pull the whole table into API process memory.
MAX_ROWS = 5000

_DISALLOWED_KEYWORDS = re.compile(
    r"\b(insert|update|delete|drop|alter|truncate|grant|revoke|create|copy|"
    r"call|execute|attach|vacuum|reindex|merge|listen|notify)\b",
    re.IGNORECASE,
)


def _validate_select_only(sql: str) -> str:
    stripped = sql.strip().rstrip(";").strip()
    if not stripped:
        raise HTTPException(status_code=400, detail="Empty query.")
    if ";" in stripped:
        raise HTTPException(
            status_code=400,
            detail="Only a single statement is allowed (no ';' inside the query).",
        )
    if not re.match(r"^(select|with)\b", stripped, re.IGNORECASE):
        raise HTTPException(
            status_code=400,
            detail="Only read-only SELECT (or WITH ... SELECT) queries are allowed here.",
        )
    if _DISALLOWED_KEYWORDS.search(stripped):
        raise HTTPException(
            status_code=400,
            detail="Query contains a disallowed keyword - this console is read-only.",
        )
    return stripped


async def _run_select(sql: str, limit: int):
    stripped = _validate_select_only(sql)
    conn = await asyncpg.connect(state.DB_URL)
    try:
        # Wrapping (rather than string-appending "LIMIT n") caps the result
        # set no matter what the user's own query already contains - their
        # own ORDER BY/LIMIT still applies first, this just backstops it.
        wrapped = f"SELECT * FROM ({stripped}) AS user_query LIMIT $1"
        try:
            rows = await conn.fetch(wrapped, limit)
        except asyncpg.PostgresError as exc:
            raise HTTPException(status_code=400, detail=f"Query failed: {exc}")
        columns = list(rows[0].keys()) if rows else []
        return columns, [dict(r) for r in rows]
    finally:
        await conn.close()


@router.get("/schema", summary="List queryable tables and columns")
async def schema():
    conn = await asyncpg.connect(state.DB_URL)
    try:
        rows = await conn.fetch(
            """
            SELECT table_name, column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = 'public'
            ORDER BY table_name, ordinal_position
            """
        )
    finally:
        await conn.close()

    tables = {}
    for r in rows:
        tables.setdefault(r["table_name"], []).append(
            {"column": r["column_name"], "type": r["data_type"]}
        )
    return tables


@router.get("/run", summary="Run a read-only SQL query against the Rossmann database")
async def run_query(
    sql: str = Query(..., description="A single SELECT (or WITH ... SELECT) statement."),
    limit: int = Query(500, gt=0, le=MAX_ROWS, description="Max rows to return."),
):
    columns, records = await _run_select(sql, limit)
    return {"columns": columns, "row_count": len(records), "rows": records}


@router.get("/download", summary="Run a read-only SQL query and download the result as CSV")
async def download_query(
    sql: str = Query(..., description="A single SELECT (or WITH ... SELECT) statement."),
    limit: int = Query(MAX_ROWS, gt=0, le=MAX_ROWS, description="Max rows to include."),
):
    columns, records = await _run_select(sql, limit)

    buffer = io.StringIO()
    writer = csv.writer(buffer)
    if columns:
        writer.writerow(columns)
        for row in records:
            writer.writerow([row[c] for c in columns])
    buffer.seek(0)

    return StreamingResponse(
        iter([buffer.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=query_result.csv"},
    )
