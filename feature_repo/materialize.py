from datetime import datetime, timezone
from feast import FeatureStore

def run_materialization():
    print("Connecting to Feast Feature Store...")
    store = FeatureStore(repo_path=".")
    
    # Set the end date to the end of 2026 to capture your training historical data
    end_date = datetime(2026, 12, 31, tzinfo=timezone.utc)
    start_date = datetime(2010, 1, 1, tzinfo=timezone.utc)
    
    print(f"Materializing features from {start_date.date()} to {end_date.date()} into Redis...")
    store.materialize(start_date, end_date)
    print("Materialization successfully finished! Redis is now packed with the latest features.")

if __name__ == "__main__":
    run_materialization()