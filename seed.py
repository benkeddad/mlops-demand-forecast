import pandas as pd
from sqlalchemy import create_engine

# Connects to the Docker Postgres database exposed on your localhost port
engine = create_engine("postgresql://user:password@localhost:5432/rossmann")

print("Reading your CSV file...")
df = pd.read_csv("data/raw/train.csv")  # Make sure this path points to your file

print("Uploading records to PostgreSQL...")
# This pushes rows to the database and automatically wakes up your training trigger
df.to_sql("train", engine, if_exists="append", index=False)
print(f"Done! Successfully loaded {len(df)} rows.")