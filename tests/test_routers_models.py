from unittest.mock import MagicMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routers import models as models_router

app = FastAPI()
app.include_router(models_router.router)
client = TestClient(app)


def _fake_registered_model(name, versions):
    m = MagicMock()
    m.name = name
    m.latest_versions = [MagicMock(version=v) for v in versions]
    return m


def test_list_models():
    fake_client = MagicMock()
    fake_client.search_registered_models.return_value = [
        _fake_registered_model("Rossmann_XGBoost_Model", ["3"])
    ]
    with patch("app.routers.models._client", return_value=fake_client):
        resp = client.get("/models")

    assert resp.status_code == 200
    assert resp.json() == [{"name": "Rossmann_XGBoost_Model", "latest_versions": ["3"]}]


def test_current_model_returns_503_when_nothing_loaded():
    with patch("app.routers.models.state.get_model", return_value=None):
        resp = client.get("/models/current")

    assert resp.status_code == 503


def test_list_versions_404_when_none_found():
    fake_client = MagicMock()
    fake_client.search_model_versions.return_value = []
    with patch("app.routers.models._client", return_value=fake_client):
        resp = client.get("/models/DoesNotExist/versions")

    assert resp.status_code == 404


def test_rollback_reloads_model_by_version():
    with patch("app.routers.models.state.load_model", return_value=True) as mock_load, \
         patch("app.routers.models.state.REGISTERED_MODEL_NAME", "Rossmann_XGBoost_Model"):
        resp = client.post("/models/rollback/5")

    assert resp.status_code == 200
    mock_load.assert_called_once_with("models:/Rossmann_XGBoost_Model/5")


def test_rollback_returns_400_when_load_fails():
    with patch("app.routers.models.state.load_model", return_value=False):
        resp = client.post("/models/rollback/5")

    assert resp.status_code == 400
