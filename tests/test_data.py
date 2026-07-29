import pandas as pd

from src.data import split_data


def test_split_data_drops_target_and_feast_identifier_columns():
    df = pd.DataFrame({
        "Store": range(20),
        "Sales": range(100, 120),
        "entity_id": range(20),
        "event_timestamp": pd.Timestamp.now(),
    })
    X_train, X_val, y_train, y_val = split_data(df, target_col="Sales")

    for X in (X_train, X_val):
        assert "Sales" not in X.columns
        assert "entity_id" not in X.columns
        assert "event_timestamp" not in X.columns

    assert len(X_train) + len(X_val) == 20
    assert len(y_train) + len(y_val) == 20


def test_split_data_uses_80_20_split():
    df = pd.DataFrame({"Store": range(10), "Sales": range(10)})
    X_train, X_val, y_train, y_val = split_data(df, target_col="Sales")
    assert len(X_train) == 8
    assert len(X_val) == 2
    assert len(y_train) == 8
    assert len(y_val) == 2


def test_split_data_is_reproducible_across_calls():
    df = pd.DataFrame({"Store": range(10), "Sales": range(10)})
    first = split_data(df, target_col="Sales")
    second = split_data(df, target_col="Sales")
    for a, b in zip(first, second):
        assert list(a.index) == list(b.index)


def test_split_data_tolerates_missing_feast_columns():
    # Not every caller's DataFrame has gone through the Feast-enriched path
    df = pd.DataFrame({"Store": range(10), "Sales": range(10)})
    X_train, X_val, y_train, y_val = split_data(df, target_col="Sales")
    assert "Sales" not in X_train.columns
