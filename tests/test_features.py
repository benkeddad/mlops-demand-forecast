import pandas as pd

from src.features import FEATURE_COLUMNS, build_features


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


def test_feature_columns_matches_model_training_order():
    # app/main.py, src/predict_initial.py, and monitoring/drift.py all slice
    # on this exact order before calling .predict() - it must never drift.
    assert FEATURE_COLUMNS == [
        "Store", "DayOfWeek", "Promo", "StateHoliday",
        "SchoolHoliday", "Year", "Month", "Day",
    ]
