import numpy as np
import pytest

from src.evaluate import calculate_rmspe, regression_metrics


def test_calculate_rmspe_perfect_predictions_is_zero():
    y_true = np.array([100.0, 200.0, 300.0])
    y_pred = np.array([100.0, 200.0, 300.0])
    assert calculate_rmspe(y_true, y_pred) == 0.0


def test_calculate_rmspe_known_percentage_error():
    y_true = np.array([100.0, 200.0])
    y_pred = np.array([110.0, 180.0])  # +10% and -10% error
    result = calculate_rmspe(y_true, y_pred)
    assert result == pytest.approx(0.1, rel=1e-6)


def test_calculate_rmspe_masks_out_zero_sales_days():
    # A zero-actual-sales day would be a division by zero (undefined percentage
    # error) if it weren't filtered out of the denominator first.
    y_true = np.array([0.0, 100.0])
    y_pred = np.array([9999.0, 100.0])  # wildly wrong on the masked day
    result = calculate_rmspe(y_true, y_pred)
    assert result == 0.0
    assert np.isfinite(result)


def test_calculate_rmspe_returns_python_float():
    y_true = np.array([100.0])
    y_pred = np.array([90.0])
    result = calculate_rmspe(y_true, y_pred)
    assert isinstance(result, float)


def test_regression_metrics_perfect_predictions():
    y_true = np.array([100.0, 200.0, 300.0])
    y_pred = np.array([100.0, 200.0, 300.0])
    metrics = regression_metrics(y_true, y_pred)
    assert metrics["rmspe"] == 0.0
    assert metrics["rmse"] == 0.0
    assert metrics["mae"] == 0.0
    assert metrics["r2"] == pytest.approx(1.0)


def test_regression_metrics_includes_rmspe_consistent_with_calculate_rmspe():
    y_true = np.array([100.0, 200.0, 0.0])
    y_pred = np.array([110.0, 180.0, 9999.0])
    metrics = regression_metrics(y_true, y_pred)
    assert metrics["rmspe"] == calculate_rmspe(y_true, y_pred)
    assert set(metrics.keys()) == {"rmspe", "rmse", "mae", "r2"}
