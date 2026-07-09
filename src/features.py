import os
import subprocess
import sys
import pandas as pd

FEATURE_COLUMNS = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
_HOLIDAY_MAP = {"0": 0, "a": 1, "b": 2, "c": 3}

def build_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    if "Date" in df.columns:
        dt = pd.to_datetime(df["Date"])
        df["Year"]  = dt.dt.year
        df["Month"] = dt.dt.month
        df["Day"]   = dt.dt.day
        df.drop(columns=["Date"], inplace=True)

    if "StateHoliday" in df.columns:
        df["StateHoliday"] = (
            df["StateHoliday"].astype(str).str.strip()
            .map(_HOLIDAY_MAP).fillna(0).astype(int)
        )

    drop_cols = [c for c in ("Customers", "Open", "Id") if c in df.columns]
    if drop_cols:
        df.drop(columns=drop_cols, inplace=True)

    df.fillna(0, inplace=True)
    return df

if __name__ == "__main__":
    print("Running Feature Engineering...")
    try:
        clean_df = pd.read_parquet("data/processed/clean_data.parquet")
        
        # FIX: Map lowercase Postgres columns to the expected capitalized names
        column_mapping = {
            "store": "Store",
            "dayofweek": "DayOfWeek",
            "sales": "Sales",
            "customers": "Customers",
            "open": "Open",
            "promo": "Promo",
            "stateholiday": "StateHoliday",
            "schoolholiday": "SchoolHoliday",
            "date": "Date",
            "id": "Id"
        }
        clean_df = clean_df.rename(columns=column_mapping)
        
        processed_df = build_features(clean_df)
        
        # Add Feast identifiers required for online synchronization
        processed_df["entity_id"] = processed_df["Store"].astype(int)
        processed_df["event_timestamp"] = pd.Timestamp.now()

        processed_df.to_parquet("data/processed/train_features.parquet", index=False)
        print("Saved train_features.parquet")

        # Sync features to Redis via Feast
        subprocess.run(["feast", "apply"], cwd="feature_repo", check=True)
        subprocess.run(["feast", "materialize-incremental", pd.Timestamp.now().isoformat()], cwd="feature_repo", check=True)

    except Exception as e:
        print(f"Pipeline error: {e}")
        subprocess.run([sys.executable, "pipelines/training_pipeline.py"], check=True)