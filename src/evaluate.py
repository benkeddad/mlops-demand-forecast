import numpy as np
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

def calculate_rmspe(y_true: np.ndarray, y_pred: np.ndarray) -> float:
    """Calculates the Root Mean Square Percentage Error."""
    # Avoid division by zero by filtering out zero sales days
    mask = y_true != 0
    y_true_filtered = y_true[mask]
    y_pred_filtered = y_pred[mask]
    
    rmspe = np.sqrt(np.mean(((y_true_filtered - y_pred_filtered) / y_true_filtered) ** 2))
    return float(rmspe)


def regression_metrics(y_true: np.ndarray, y_pred: np.ndarray) -> dict:
    """Fuller metric set for src/train_optimal.py's Optuna objective/final
    evaluation - rmspe (via calculate_rmspe, unchanged) plus rmse/mae/r2."""
    return {
        "rmspe": calculate_rmspe(y_true, y_pred),
        "rmse": float(np.sqrt(mean_squared_error(y_true, y_pred))),
        "mae": float(mean_absolute_error(y_true, y_pred)),
        "r2": float(r2_score(y_true, y_pred)),
    }