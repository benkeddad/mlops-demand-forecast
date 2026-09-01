import pandas as pd
import pytest

from src.serving_features import HISTORY_LOOKBACK_DAYS, compute_prediction_features, needs_sales_history


def test_needs_sales_history_true_for_rich_columns():
    assert needs_sales_history(["Store", "SalesLag1", "SalesRollingMean7"]) is True


def test_needs_sales_history_false_for_lean_columns():
    assert needs_sales_history(["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]) is False


def test_compute_prediction_features_lean_path_needs_no_history():
    new_rows = pd.DataFrame({
        "Store": [5], "Date": [pd.Timestamp("2015-06-15")], "DayOfWeek": [1],
        "Promo": [1], "StateHoliday": ["0"], "SchoolHoliday": [0],
    })
    lean_cols = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
    result = compute_prediction_features(new_rows, lean_cols, history_df=None)
    assert list(result.columns) == lean_cols
    assert result.loc[0, "Year"] == 2015
    assert result.loc[0, "Month"] == 6


def test_compute_prediction_features_rich_path_computes_correct_lag_and_rolling():
    dates = pd.date_range("2015-01-01", periods=30, freq="D")
    history = pd.DataFrame({
        "Store": 1, "Date": dates, "Sales": range(100, 130),
        "DayOfWeek": dates.dayofweek + 1, "Promo": 0, "StateHoliday": "0", "SchoolHoliday": 0,
    })
    new_rows = pd.DataFrame({
        "Store": [1], "Date": [pd.Timestamp("2015-01-31")], "DayOfWeek": [6],
        "Promo": [0], "StateHoliday": ["0"], "SchoolHoliday": [0],
    })
    result = compute_prediction_features(new_rows, ["SalesLag1", "SalesLag7", "SalesRollingMean7"], history_df=history)
    assert result.loc[0, "SalesLag1"] == 129
    assert result.loc[0, "SalesLag7"] == 123
    assert result.loc[0, "SalesRollingMean7"] == pytest.approx(sum(range(123, 130)) / 7)


def test_compute_prediction_features_rich_path_raises_without_history():
    new_rows = pd.DataFrame({"Store": [1], "Date": [pd.Timestamp("2015-01-31")], "DayOfWeek": [6]})
    with pytest.raises(ValueError, match="requires Sales-history"):
        compute_prediction_features(new_rows, ["SalesLag1"], history_df=None)


def test_compute_prediction_features_rich_path_raises_on_empty_history():
    new_rows = pd.DataFrame({"Store": [1], "Date": [pd.Timestamp("2015-01-31")], "DayOfWeek": [6]})
    with pytest.raises(ValueError, match="requires Sales-history"):
        compute_prediction_features(new_rows, ["SalesLag1"], history_df=pd.DataFrame())


def test_compute_prediction_features_does_not_cross_contaminate_stores():
    dates = pd.date_range("2015-01-01", periods=10, freq="D")
    history = pd.concat([
        pd.DataFrame({"Store": 1, "Date": dates, "Sales": 100, "DayOfWeek": dates.dayofweek + 1}),
        pd.DataFrame({"Store": 2, "Date": dates, "Sales": 999, "DayOfWeek": dates.dayofweek + 1}),
    ], ignore_index=True)
    new_rows = pd.DataFrame({
        "Store": [1, 2], "Date": [pd.Timestamp("2015-01-11")] * 2, "DayOfWeek": [7, 7],
    })
    result = compute_prediction_features(new_rows, ["Store", "SalesLag1"], history_df=history)
    assert result.loc[result["Store"] == 1, "SalesLag1"].item() == 100
    assert result.loc[result["Store"] == 2, "SalesLag1"].item() == 999


def test_compute_prediction_features_raises_on_missing_model_column():
    new_rows = pd.DataFrame({"Store": [5], "Date": [pd.Timestamp("2015-06-15")], "DayOfWeek": [1]})
    with pytest.raises(ValueError, match="missing column"):
        compute_prediction_features(new_rows, ["ThisColumnWillNeverExist"], history_df=None)


def test_compute_prediction_features_returns_columns_in_model_signature_order():
    new_rows = pd.DataFrame({
        "Store": [5], "Date": [pd.Timestamp("2015-06-15")], "DayOfWeek": [1],
        "Promo": [1], "StateHoliday": ["0"], "SchoolHoliday": [0],
    })
    # Deliberately out of build_features()'s natural column order
    reordered = ["Day", "Store", "Month", "DayOfWeek"]
    result = compute_prediction_features(new_rows, reordered, history_df=None)
    assert list(result.columns) == reordered


def test_history_lookback_days_covers_the_longest_lag_feature():
    # SalesLag28 needs at least 28 days of prior history to ever be non-zero
    # for a store with continuous sales data - the lookback window must be
    # comfortably larger than that (weekends/holidays can create gaps).
    assert HISTORY_LOOKBACK_DAYS > 28
