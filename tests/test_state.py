from unittest.mock import MagicMock, patch

from app import state


def test_load_model_success_updates_model_and_uri():
    fake_model = MagicMock()
    with patch("app.state.mlflow.pyfunc.load_model", return_value=fake_model) as mock_load:
        ok = state.load_model("models:/Rossmann_XGBoost_Model/7")

    assert ok is True
    assert state.get_model() is fake_model
    assert state.get_model_uri() == "models:/Rossmann_XGBoost_Model/7"
    mock_load.assert_called_once_with("models:/Rossmann_XGBoost_Model/7")


def test_load_model_defaults_to_default_model_uri():
    with patch("app.state.mlflow.pyfunc.load_model", return_value=MagicMock()) as mock_load:
        state.load_model()

    mock_load.assert_called_once_with(state.DEFAULT_MODEL_URI)


def test_load_model_failure_returns_false_and_keeps_uri_unset():
    with patch("app.state.mlflow.pyfunc.load_model", side_effect=RuntimeError("boom")):
        ok = state.load_model("models:/Rossmann_XGBoost_Model/999")

    assert ok is False
