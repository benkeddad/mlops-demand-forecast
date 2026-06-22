import pandas as pd

# Must match FEATURE_COLUMNS in app/main.py exactly
FEATURE_COLUMNS = [
    "Store", "DayOfWeek", "Promo",
    "StateHoliday", "SchoolHoliday",
    "Year", "Month", "Day",
]

# Rossmann StateHoliday encoding: '0' = none, 'a/b/c' = holiday types
_HOLIDAY_MAP = {"0": 0, "a": 1, "b": 2, "c": 3}


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Transforms raw Rossmann CSV into the 8 features the XGBoost model expects.
    Output columns: Store, DayOfWeek, Promo, StateHoliday, SchoolHoliday,
                    Year, Month, Day  — plus 'Sales' if it is present (training).
    """
    df = df.copy()

    # 1. Expand Date → Year / Month / Day
    #    (DayOfWeek already exists in the raw file, so we don't overwrite it)
    if "Date" in df.columns:
        dt = pd.to_datetime(df["Date"])
        df["Year"]  = dt.dt.year
        df["Month"] = dt.dt.month
        df["Day"]   = dt.dt.day
        df.drop(columns=["Date"], inplace=True)

    # 2. Encode StateHoliday as integer  ('0'→0, 'a'→1, 'b'→2, 'c'→3)
    if "StateHoliday" in df.columns:
        df["StateHoliday"] = (
            df["StateHoliday"].astype(str).str.strip()
            .map(_HOLIDAY_MAP).fillna(0).astype(int)
        )

    # 3. Drop columns that are not available at inference time
    #    Customers: unknown before a sale happens
    #    Open:      not part of the API schema
    #    Id:        Kaggle submission ID, not a feature
    drop_cols = [c for c in ("Customers", "Open", "Id") if c in df.columns]
    if drop_cols:
        df.drop(columns=drop_cols, inplace=True)

    # 4. Fill any remaining NaN
    df.fillna(0, inplace=True)

    return df