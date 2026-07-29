import os
import pandas as pd
from sqlalchemy import create_engine, text

# FIX 1: Read the DATABASE_URL environment variable set in docker-compose
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@postgres:5432/rossmann")
engine = create_engine(DATABASE_URL)

# Check if train table already has data
with engine.connect() as conn:
    train_count = conn.execute(text("SELECT COUNT(*) FROM train")).scalar()

if train_count > 0:
    print(f"Database already contains {train_count} records in train. Skipping data seed.")
else:
    print("Reading your CSV file...")
    df = pd.read_csv("data/raw/train.csv", low_memory=False)

    # 1. Convert CSV column names to lowercase to match the PostgreSQL schema exactly
    df.columns = df.columns.str.lower()

    # 2. FIX: Convert the string dates to proper datetime objects
    # Using dayfirst=True handles European DD/MM/YYYY formats perfectly
    df['date'] = pd.to_datetime(df['date'], dayfirst=True)

    print("Uploading records to PostgreSQL...")
    df.to_sql("train", engine, if_exists="append", index=False, chunksize=10000)

    print(f"Done! Successfully loaded {len(df)} rows to the train table.")


# Check if test table already has data
with engine.connect() as conn:
    test_count = conn.execute(text("SELECT COUNT(*) FROM test")).scalar()

if test_count > 0:
    print(f"Database already contains {test_count} records in test. Skipping data seed.")
else:
    print("Reading test.csv file...")
    test_df = pd.read_csv("data/test.csv")

    print("Uploading records to test table...")
    test_df.columns = test_df.columns.str.lower()
    test_df['date'] = pd.to_datetime(test_df['date'], dayfirst=True)
    test_df.to_sql("test", engine, if_exists="append", index=False, chunksize=10000)