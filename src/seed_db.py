import os
import pandas as pd
from sqlalchemy import create_engine

# FIX 1: Read the DATABASE_URL environment variable set in docker-compose
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:password@postgres:5432/rossmann")
engine = create_engine(DATABASE_URL)

print("Reading your CSV file...")
# This path is correct because the Dockerfile copies your data folder to /app/data
df = pd.read_csv("data/raw/train.csv")  

print("Uploading records to PostgreSQL...")
# FIX 2: Use chunksize so loading 1M+ rows doesn't break the container
df.to_sql("train", engine, if_exists="append", index=False, chunksize=10000)

print(f"Done! Successfully loaded {len(df)} rows to the train table.")


print("Reading test.csv file...")
test_df = pd.read_csv("data/raw/test.csv")

print("Uploading records to test table...")
test_df.to_sql("test", engine, if_exists="append", index=False, chunksize=10000)