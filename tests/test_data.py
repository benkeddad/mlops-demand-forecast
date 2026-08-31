import pandas as pd

from src.data import split_data, split_data_time_ordered


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


def test_split_data_time_ordered_holds_out_the_latest_rows():
    # src/features.py's build_features() breaks Date into Year/Month/Day and
    # drops Date entirely - split_data_time_ordered() reconstructs the sort
    # key from those three columns rather than a live Date column.
    df = pd.DataFrame({
        "Store": [1] * 10,
        "Year": [2015] * 10,
        "Month": [1] * 5 + [2] * 5,
        "Day": list(range(1, 6)) + list(range(1, 6)),
        "Sales": range(100, 110),
    })
    X_train, X_val, y_train, y_val = split_data_time_ordered(df, target_col="Sales", validation_fraction=0.2)
    assert len(X_val) == 2
    assert len(X_train) == 8
    # The held-out rows are the chronologically latest ones (Feb 4, Feb 5),
    # not an arbitrary/random slice.
    assert set(y_val.values) == {108, 109}


def test_split_data_time_ordered_drops_target_and_feast_identifier_columns():
    df = pd.DataFrame({
        "Store": range(20),
        "Year": [2015] * 20,
        "Month": [1] * 20,
        "Day": list(range(1, 21)),
        "Sales": range(100, 120),
        "entity_id": range(20),
        "event_timestamp": pd.Timestamp.now(),
    })
    X_train, X_val, y_train, y_val = split_data_time_ordered(df, target_col="Sales")
    for X in (X_train, X_val):
        assert "Sales" not in X.columns
        assert "entity_id" not in X.columns
        assert "event_timestamp" not in X.columns
    assert len(X_train) + len(X_val) == 20


def test_split_data_time_ordered_falls_back_to_row_order_without_date_parts():
    # No Year/Month/Day columns at all - falls back to sort_index() rather
    # than erroring.
    df = pd.DataFrame({"Store": range(10), "Sales": range(10)})
    X_train, X_val, y_train, y_val = split_data_time_ordered(df, target_col="Sales", validation_fraction=0.2)
    assert len(X_val) == 2
    assert len(X_train) == 8
