from unittest.mock import AsyncMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routers import query as query_router

app = FastAPI()
app.include_router(query_router.router)
client = TestClient(app)


def _fake_connection(fetch_return=None):
    conn = AsyncMock()
    if fetch_return is not None:
        conn.fetch.return_value = fetch_return
    return conn


def test_run_query_returns_columns_and_rows():
    conn = _fake_connection(fetch_return=[{"store": 1, "cnt": 100}, {"store": 2, "cnt": 90}])
    with patch("app.routers.query.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.get(
            "/query/run",
            params={"sql": "SELECT store, COUNT(*) as cnt FROM train GROUP BY store"},
        )

    assert resp.status_code == 200
    assert resp.json() == {
        "columns": ["store", "cnt"],
        "row_count": 2,
        "rows": [{"store": 1, "cnt": 100}, {"store": 2, "cnt": 90}],
    }
    conn.close.assert_awaited_once()


def test_run_query_wraps_with_row_limit():
    conn = _fake_connection(fetch_return=[])
    with patch("app.routers.query.asyncpg.connect", AsyncMock(return_value=conn)):
        client.get("/query/run", params={"sql": "SELECT * FROM test", "limit": 10})

    sql_sent, limit_sent = conn.fetch.call_args.args
    assert sql_sent == "SELECT * FROM (SELECT * FROM test) AS user_query LIMIT $1"
    assert limit_sent == 10


def test_download_query_returns_csv_attachment():
    conn = _fake_connection(fetch_return=[{"store": 1, "cnt": 100}])
    with patch("app.routers.query.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.get("/query/download", params={"sql": "SELECT store, COUNT(*) as cnt FROM train GROUP BY store"})

    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/csv")
    assert "attachment; filename=query_result.csv" in resp.headers["content-disposition"]
    assert resp.text == "store,cnt\r\n1,100\r\n"


def test_run_query_rejects_multiple_statements():
    resp = client.get("/query/run", params={"sql": "SELECT 1; DROP TABLE train;"})
    assert resp.status_code == 400


def test_run_query_rejects_non_select_statements():
    resp = client.get("/query/run", params={"sql": "DELETE FROM train"})
    assert resp.status_code == 400


def test_run_query_rejects_empty_sql():
    resp = client.get("/query/run", params={"sql": "   "})
    assert resp.status_code == 400


def test_run_query_allows_cte_select():
    conn = _fake_connection(fetch_return=[])
    with patch("app.routers.query.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.get(
            "/query/run",
            params={"sql": "WITH t AS (SELECT * FROM train) SELECT * FROM t"},
        )
    assert resp.status_code == 200


def test_schema_groups_columns_by_table():
    conn = _fake_connection(
        fetch_return=[
            {"table_name": "train", "column_name": "store", "data_type": "integer"},
            {"table_name": "train", "column_name": "date", "data_type": "date"},
            {"table_name": "test", "column_name": "id", "data_type": "integer"},
        ]
    )
    with patch("app.routers.query.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.get("/query/schema")

    assert resp.status_code == 200
    body = resp.json()
    assert body["train"] == [
        {"column": "store", "type": "integer"},
        {"column": "date", "type": "date"},
    ]
    assert body["test"] == [{"column": "id", "type": "integer"}]
