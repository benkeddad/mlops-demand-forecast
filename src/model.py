import xgboost as xgb

def get_model(learning_rate=0.1, max_depth=6, n_estimators=100, **kwargs):
    """Initializes and returns the XGBoost Regressor. Extra keyword args
    (subsample, colsample_bytree, reg_alpha, tree_method, ...) are forwarded
    straight to XGBRegressor - added for src/train_optimal.py's RFECV/Optuna
    search, which needs a much larger hyperparameter surface than the three
    named params src/train.py's fast path uses. Existing calls are
    unaffected: the three named defaults below are unchanged, and nothing
    new is baked in as a default - a caller that doesn't pass the new
    kwargs gets exactly the same model as before.
    """
    params = {
        'objective': 'reg:squarederror',
        'learning_rate': learning_rate,
        'max_depth': max_depth,
        'n_estimators': n_estimators,
        'random_state': 42,
    }
    params.update(kwargs)
    return xgb.XGBRegressor(**params)