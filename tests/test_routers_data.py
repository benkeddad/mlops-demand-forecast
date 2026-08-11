import io
from unittest.mock import AsyncMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routers import data as data_router

app = FastAPI()
app.include_router(data_router.router)
client = TestClient(app)

_TRAIN_CSV = (
    b"Store,DayOfWeek,Date,Sales,Customers,Open,Promo,StateHoliday,SchoolHoliday\n"
    b"1,5,2015-07-31,5263,555,1,1,0,1\n"
    b"2,5,2015-07-31,6064,625,1,1,0,1\n"
)
# Kaggle-shaped test.csv: has an Id column (must be dropped) and a blank
# Open value (must default to 1, per the dataset's own convention).
_TEST_CSV = (
    b"Id,Store,DayOfWeek,Date,Open,Promo,StateHoliday,SchoolHoliday\n"
    b"1,1,4,2015-09-17,1,1,0,0\n"
    b"2,3,4,2015-09-17,,1,0,0\n"
)


def _fake_copy_connection():
    conn = AsyncMock()
    conn.copy_records_to_table = AsyncMock()
    return conn


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


def test_upload_train_csv_copies_normalized_rows():
    conn = _fake_copy_connection()
    with patch("app.routers.data.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.post(
            "/data/upload/train",
            files={"file": ("train.csv", _TRAIN_CSV, "text/csv")},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["rows_inserted"] == 2
    assert body["table"] == "train"
    conn.copy_records_to_table.assert_awaited_once()
    _, kwargs = conn.copy_records_to_table.call_args
    assert kwargs["columns"] == data_router._TRAIN_COLUMNS
    conn.close.assert_awaited_once()


def test_upload_test_csv_drops_id_and_defaults_blank_open():
    conn = _fake_copy_connection()
    with patch("app.routers.data.asyncpg.connect", AsyncMock(return_value=conn)):
        resp = client.post(
            "/data/upload/test",
            files={"file": ("test.csv", _TEST_CSV, "text/csv")},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["rows_inserted"] == 2
    _, kwargs = conn.copy_records_to_table.call_args
    assert kwargs["columns"] == data_router._TEST_COLUMNS
    assert "id" not in kwargs["columns"]
    open_index = kwargs["columns"].index("open")
    assert kwargs["records"][1][open_index] == 1  # blank Open -> defaulted to 1


def test_upload_rejects_non_csv_file():
    resp = client.post(
        "/data/upload/train",
        files={"file": ("notes.txt", b"not a csv", "text/plain")},
    )
    assert resp.status_code == 400


def test_upload_rejects_csv_missing_required_columns():
    resp = client.post(
        "/data/upload/train",
        files={"file": ("test.csv", _TEST_CSV, "text/csv")},  # missing sales/customers
    )
    assert resp.status_code == 400
    assert "sales" in resp.json()["detail"]


def test_upload_train_requires_api_key_when_set():
    with patch("app.auth.API_KEY", "secret"):
        resp = client.post(
            "/data/upload/train",
            files={"file": ("train.csv", _TRAIN_CSV, "text/csv")},
        )
    assert resp.status_code == 401
