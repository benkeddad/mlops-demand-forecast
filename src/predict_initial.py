import os
import sys
import pandas as pd
import mlflow.pyfunc
from sqlalchemy import create_engine, text

# Import your existing local processing logic
from features import build_features

# ============================================================
# CONFIGURATION & ENVIRONMENT SETUP
# ============================================================
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@postgres:5432/rossmann")
MODEL_URI = os.getenv("MODEL_URI", "models:/Rossmann_XGBoost_Model/latest")
MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://mlflow:5000")

mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)

def main():
    engine = create_engine(DATABASE_URL)
    
    # 1. FETCH UNPREDICTED ROWS WITH ALL THEIR TEMPORAL COLUMNS
    print("Fetching unpredicted records from the 'test' table...")
    query = """
        SELECT id, store, date, dayofweek, promo, stateholiday, schoolholiday 
        FROM test 
        WHERE predicted_sales IS NULL;
    """
    
    try:
        df = pd.read_sql(query, engine)
    except Exception as e:
        print(f"Database error: {e}")
        sys.exit(1)
        
    if df.empty:
        print("No unpredicted records found in the 'test' table. Skipping initial batch prediction.")
        return

    print(f"Batch prediction triggered. Processing {len(df)} new rows...")

    # 2. LOAD THE MODEL FROM MLFLOW
    print(f"Loading model from MLflow Registry: {MODEL_URI}")
    try:
        model = mlflow.pyfunc.load_model(MODEL_URI)
    except Exception as e:
        print(f"Failed to load model from MLflow: {e}")
        sys.exit(1)

    # 3. MAP COLUMNS AND PROCESS THE TEMPORAL FEATURES LOCALLY
    # Map lowercase DB column names to what build_features expects
    column_mapping = {
        "store": "Store",
        "dayofweek": "DayOfWeek",
        "promo": "Promo",
        "stateholiday": "StateHoliday",
        "schoolholiday": "SchoolHoliday",
        "date": "Date"
    }
    df_renamed = df.rename(columns=column_mapping)
    
    print("Processing date and categorical features locally...")
    # This automatically splits 'Date' into 'Year', 'Month', and 'Day'
    processed_df = build_features(df_renamed)

    # Enforce strict formatting and feature order to align with XGBoost matrix
    expected_features = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
    features_only = processed_df[expected_features].copy()
    features_only = features_only.apply(pd.to_numeric, errors="coerce").fillna(0).astype(int)
    
    # 4. RUN BATCH INFERENCE
    print("Running batch inference...")
    try:
        predictions = model.predict(features_only)
    except Exception as e:
        print(f"Prediction failed: {e}")
        sys.exit(1)
    
    # 5. BULK WRITE PREDICTIONS BACK TO POSTGRESQL
    print("Writing batch predictions back to 'test' table...")
    update_query = text("UPDATE test SET predicted_sales = :predicted_sales WHERE id = :id")
    
    # Map predictions back to the original database row IDs
    update_payload = [
        {"predicted_sales": float(pred), "id": int(db_id)} 
        for pred, db_id in zip(predictions, df["id"])
    ]
    
    with engine.begin() as conn:
        conn.execute(update_query, update_payload)
        
    print(f"Batch prediction successfully written to database for {len(df)} records.")

if __name__ == "__main__":
    main()