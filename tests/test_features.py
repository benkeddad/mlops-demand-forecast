import pandas as pd
import pytest

from src.features import FEATURE_COLUMNS, RICH_HISTORY_DEPENDENT_PREFIXES, build_features, build_features_rich


def test_build_features_splits_date_into_year_month_day():
    df = pd.DataFrame({"Date": ["2015-06-21"], "Store": [1]})
    result = build_features(df)
    assert result.loc[0, "Year"] == 2015
    assert result.loc[0, "Month"] == 6
    assert result.loc[0, "Day"] == 21
    assert "Date" not in result.columns


def test_build_features_maps_state_holiday_codes_to_ints():
    # Same mapping used at both training time and in the real-time Feast path
    df = pd.DataFrame({"StateHoliday": ["0", "a", "b", "c"]})
    result = build_features(df)
    assert list(result["StateHoliday"]) == [0, 1, 2, 3]


def test_build_features_defaults_unknown_holiday_code_to_zero():
    df = pd.DataFrame({"StateHoliday": ["unexpected"]})
    result = build_features(df)
    assert result.loc[0, "StateHoliday"] == 0


def test_build_features_drops_leakage_and_identifier_columns():
    df = pd.DataFrame({"Store": [1], "Customers": [50], "Open": [1], "Id": [7]})
    result = build_features(df)
    assert "Customers" not in result.columns
    assert "Open" not in result.columns
    assert "Id" not in result.columns
    assert "Store" in result.columns


def test_build_features_fills_missing_values_with_zero():
    df = pd.DataFrame({"Store": [1, None]})
    result = build_features(df)
    assert result["Store"].isna().sum() == 0


def test_build_features_does_not_mutate_input_frame():
    df = pd.DataFrame({"Date": ["2015-06-21"]})
    build_features(df)
    assert "Date" in df.columns  # original untouched thanks to df.copy()


def test_build_features_normalizes_lowercase_db_columns():
    df = pd.DataFrame({
        "store": [1],
        "date": ["2015-06-21"],
        "stateholiday": ["a"],
    })
    result = build_features(df)
    assert "Store" in result.columns
    assert "Date" not in result.columns
    assert "StateHoliday" in result.columns
    assert result.loc[0, "StateHoliday"] == 1


def test_feature_columns_matches_model_training_order():
    # app/main.py, src/predict_initial.py, and monitoring/drift.py all slice
    # on this exact order before calling .predict() - it must never drift.
    assert FEATURE_COLUMNS == [
        "Store", "DayOfWeek", "Promo", "StateHoliday",
        "SchoolHoliday", "Year", "Month", "Day",
    ]


# --- build_features_rich() (src/train_optimal.py's feature set) ---

def test_build_features_rich_keeps_date_unlike_the_lean_version():
    # Needed both to sort before computing lag/rolling windows, and at
    # serving time to merge new rows' computed features back out of a
    # combined (history + new rows) frame - see src/serving_features.py.
    df = pd.DataFrame({"Date": ["2015-06-21"], "Store": [1]})
    result = build_features_rich(df)
    assert "Date" in result.columns
    assert result.loc[0, "Year"] == 2015


def test_build_features_rich_adds_calendar_and_cyclical_columns():
    df = pd.DataFrame({"Date": ["2015-01-01"], "Store": [1], "DayOfWeek": [4]})
    result = build_features_rich(df)
    for col in ["WeekOfYear", "Quarter", "IsMonthStart", "IsMonthEnd", "DayOfYear", "MonthSin", "MonthCos", "DayOfWeekSin", "DayOfWeekCos"]:
        assert col in result.columns
    assert result.loc[0, "IsMonthStart"] == 1
    assert result.loc[0, "Quarter"] == 1


def test_build_features_rich_lag_features_only_look_backward():
    # Leakage check: a row's own Sales must never appear in its own lag/
    # rolling features - SalesLag1 for day N is day N-1's Sales, not day N's.
    # The very first row has no prior day, so its SalesLag1 is filled with 0
    # (matching build_features()'s existing "no history yet -> 0" behavior),
    # not day 1's own Sales value of 10.
    dates = pd.date_range("2015-01-01", periods=5, freq="D")
    df = pd.DataFrame({
        "Store": 1, "Date": dates, "Sales": [10, 20, 30, 40, 50],
        "DayOfWeek": dates.dayofweek + 1,
    })
    result = build_features_rich(df)
    assert result["SalesLag1"].tolist() == [0, 10, 20, 30, 40]
    assert result.loc[result["Day"] == 2, "SalesLag1"].item() == 10
    assert result.loc[result["Day"] == 5, "SalesLag1"].item() == 40


def test_build_features_rich_rolling_mean_uses_only_prior_days():
    dates = pd.date_range("2015-01-01", periods=10, freq="D")
    df = pd.DataFrame({
        "Store": 1, "Date": dates, "Sales": list(range(100, 110)),
        "DayOfWeek": dates.dayofweek + 1,
    })
    result = build_features_rich(df)
    # Day 8 (index 7, Sales=107): SalesRollingMean7 should average days 1-7
    # (100..106), NOT include day 8's own 107.
    row = result.loc[result["Day"] == 8]
    assert row["SalesRollingMean7"].item() == pytest.approx(sum(range(100, 107)) / 7)


def test_build_features_rich_does_not_leak_across_stores():
    dates = pd.date_range("2015-01-01", periods=5, freq="D")
    df = pd.concat([
        pd.DataFrame({"Store": 1, "Date": dates, "Sales": 100, "DayOfWeek": dates.dayofweek + 1}),
        pd.DataFrame({"Store": 2, "Date": dates, "Sales": 999, "DayOfWeek": dates.dayofweek + 1}),
    ], ignore_index=True)
    result = build_features_rich(df)
    store1_lag1 = result.loc[(result["Store"] == 1) & (result["Day"] == 2), "SalesLag1"].item()
    store2_lag1 = result.loc[(result["Store"] == 2) & (result["Day"] == 2), "SalesLag1"].item()
    assert store1_lag1 == 100
    assert store2_lag1 == 999


def test_build_features_rich_leaves_sales_and_date_unfilled_but_fills_engineered_columns():
    # Sales genuinely unknown for prediction rows (filling with 0 would look
    # like a real zero-sales day); engineered columns with no history yet
    # (a store's first few rows) are filled with 0, matching build_features().
    dates = pd.date_range("2015-01-01", periods=3, freq="D")
    df = pd.DataFrame({"Store": 1, "Date": dates, "Sales": [10, None, 30], "DayOfWeek": dates.dayofweek + 1})
    result = build_features_rich(df)
    assert result["Sales"].isna().sum() == 1  # untouched
    assert result["SalesLag1"].isna().sum() == 0  # filled (first row's NaN -> 0)
    assert result.loc[0, "SalesLag1"] == 0


def test_build_features_rich_normalizes_lowercase_db_columns_and_maps_holidays():
    df = pd.DataFrame({"store": [1], "date": ["2015-06-21"], "stateholiday": ["a"]})
    result = build_features_rich(df)
    assert "Store" in result.columns
    assert result.loc[0, "StateHoliday"] == 1


def test_build_features_rich_drops_customers_and_id():
    df = pd.DataFrame({"Store": [1], "Customers": [50], "Id": [7]})
    result = build_features_rich(df)
    assert "Customers" not in result.columns
    assert "Id" not in result.columns


def test_rich_history_dependent_prefixes_matches_actual_generated_columns():
    # Guards against the prefix list (src/serving_features.py's
    # needs_sales_history() check) silently drifting from what
    # build_features_rich() actually generates.
    dates = pd.date_range("2015-01-01", periods=30, freq="D")
    df = pd.DataFrame({"Store": 1, "Date": dates, "Sales": range(30), "DayOfWeek": dates.dayofweek + 1})
    result = build_features_rich(df)
    history_cols = [c for c in result.columns if c.startswith(("SalesLag", "SalesRolling", "SalesMomentum", "StoreExpanding"))]
    assert history_cols  # sanity: there are some
    assert all(col.startswith(RICH_HISTORY_DEPENDENT_PREFIXES) for col in history_cols)
