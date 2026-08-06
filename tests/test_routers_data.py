from unittest.mock import AsyncMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routers import data as data_router

app = FastAPI()
app.include_router(data_router.router)
client = TestClient(app)


def _fake_connection(fetchval_side_effect=None, fetch_return=None):
    conn = AsyncMock()
    if fetchval_side_effect is not None:
        conn.fetchval.side_effect = fetchval_side_effect
    if fetch_return is not None:
        conn.fetch.return_value = fetch_return
    return conn


def test_data_stats_reports_counts_and_coverage():
    conn = _fake_connection(fetchval_side_effect=[1017209, 41088, 0])
    with patch("app.routers.data.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.get("/data/stats")

    assert resp.status_code == 200
    assert resp.json() == {
        "train_rows": 1017209,
        "test_rows": 41088,
        "unpredicted_rows": 0,
        "predicted_rows": 41088,
    }
    conn.close.assert_awaited_once()


def test_store_predictions_404_when_no_rows():
    conn = _fake_connection(fetch_return=[])
    with patch("app.routers.data.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.get("/data/predictions/9999")

    assert resp.status_code == 404
