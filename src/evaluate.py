import numpy as np

def calculate_rmspe(y_true: np.ndarray, y_pred: np.ndarray) -> float:
    """Calculates the Root Mean Square Percentage Error."""
    # Avoid division by zero by filtering out zero sales days
    mask = y_true != 0
    y_true_filtered = y_true[mask]
    y_pred_filtered = y_pred[mask]
    
    rmspe = np.sqrt(np.mean(((y_true_filtered - y_pred_filtered) / y_true_filtered) ** 2))
    return float(rmspe)