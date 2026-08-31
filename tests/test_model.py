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


def test_get_model_forwards_extra_kwargs_used_by_optimal_training():
    # src/train_optimal.py's RFECV estimator and Optuna trials pass a much
    # wider hyperparameter surface than the three named params above.
    params = get_model(
        n_estimators=500, subsample=0.8, colsample_bytree=0.7,
        reg_alpha=0.01, reg_lambda=1.0, gamma=0.5, tree_method="hist",
    ).get_params()
    assert params["subsample"] == 0.8
    assert params["colsample_bytree"] == 0.7
    assert params["reg_alpha"] == 0.01
    assert params["tree_method"] == "hist"
    # Passing extra kwargs doesn't disturb the existing named defaults.
    assert params["learning_rate"] == 0.1
    assert params["objective"] == "reg:squarederror"
