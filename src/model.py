import xgboost as xgb

def get_model(learning_rate=0.1, max_depth=6, n_estimators=100):
    """Initializes and returns the XGBoost Regressor."""
    model = xgb.XGBRegressor(
        objective='reg:squarederror',
        learning_rate=learning_rate,
        max_depth=max_depth,
        n_estimators=n_estimators,
        random_state=42
    )
    return model