import xgboost as xgb

from src.model import get_model


def test_get_model_returns_xgbregressor():
    model = get_model()
    assert isinstance(model, xgb.XGBRegressor)


def test_get_model_defaults():
    params = get_model().get_params()
    assert params["objective"] == "reg:squarederror"
    assert params["learning_rate"] == 0.1
    assert params["max_depth"] == 6
    assert params["n_estimators"] == 100
    assert params["random_state"] == 42


def test_get_model_honors_overrides_used_by_training():
    # src/train.py calls get_model(n_estimators=150, max_depth=8)
    params = get_model(n_estimators=150, max_depth=8).get_params()
    assert params["n_estimators"] == 150
    assert params["max_depth"] == 8
    # random_state stays fixed regardless of overrides, so training is reproducible
    assert params["random_state"] == 42
