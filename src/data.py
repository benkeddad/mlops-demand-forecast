import os
import pandas as pd
from sqlalchemy import create_engine
from sklearn.model_selection import train_test_split

DB_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@localhost:5432/rossmann")

def load_data_from_db() -> pd.DataFrame:
    engine = create_engine(DB_URL)
    df = pd.read_sql("SELECT * FROM train", engine)
    return df

def split_data(df: pd.DataFrame, target_col: str):
    """Splits the processed features into training and validation sets."""
    # Drop the target and any Feast online store identifiers before splitting
    X = df.drop(columns=[target_col, "entity_id", "event_timestamp"], errors="ignore")
    y = df[target_col]
    return train_test_split(X, y, test_size=0.2, random_state=42)

if __name__ == "__main__":
    print("Running Data Ingestion from DB...")
    raw_df = load_data_from_db()
    
    os.makedirs("data/processed", exist_ok=True)
    raw_df.to_parquet("data/processed/clean_data.parquet", index=False)
    print("Saved clean_data.parquet")