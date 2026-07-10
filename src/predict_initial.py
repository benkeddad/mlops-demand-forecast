import os
import sys
import pandas as pd
import mlflow.pyfunc
from sqlalchemy import create_engine, text
from feast import FeatureStore

# ============================================================
# CONFIGURATION & ENVIRONMENT SETUP
# ============================================================
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@postgres:5432/rossmann")
MODEL_URI = os.getenv("MODEL_URI", "models:/Rossmann_XGBoost_Model/latest")
MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://mlflow:5000")

mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)

def main():
    engine = create_engine(DATABASE_URL)
    
    # 1. FETCH UNPREDICTED ROWS FROM POSTGRESQL (Matches your trigger query)
    print("Fetching unpredicted records from the 'test' table...")
    query = "SELECT id, store FROM test WHERE predicted_sales IS NULL;"
    
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

    # 3. GET ONLINE FEATURES FROM FEAST (Matches your trigger structure)
    print("Connecting to Feast Feature Store...")
    store = FeatureStore(repo_path="feature_repo") 
    
    # Map the entities exactly like your handle_predict_db_trigger function
    entity_rows = [{"entity_id": int(row["store"])} for _, row in df.iterrows()]
    
    print("Retrieving features from Feast online store...")
    feature_response = store.get_online_features(
        features=[
            "rossmann_features:Store", "rossmann_features:DayOfWeek", "rossmann_features:Promo",
            "rossmann_features:StateHoliday", "rossmann_features:SchoolHoliday",
            "rossmann_features:Year", "rossmann_features:Month", "rossmann_features:Day"
        ],
        entity_rows=entity_rows
    ).to_df()

    # 4. PROCESS FEATURES (Verbatim copy of your transformation logic)
    features_only = feature_response[["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]].copy()
    
    # Map categorical holiday strings back to integers
    holiday_map = {"0": 0, "a": 1, "b": 2, "c": 3}
    features_only["StateHoliday"] = (
        features_only["StateHoliday"].astype(str).str.strip()
        .map(holiday_map).fillna(0).astype(int)
    )

    # Coerce everything to int to align with your XGBoost training matrix
    features_only = features_only.apply(pd.to_numeric, errors="coerce").fillna(0).astype(int)
    
    # 5. RUN BATCH INFERENCE
    print("Running batch inference...")
    try:
        predictions = model.predict(features_only)
    except Exception as e:
        print(f"Prediction failed: {e}")
        sys.exit(1)
    
    # 6. BULK WRITE PREDICTIONS BACK TO POSTGRESQL
    print("Writing batch predictions back to 'test' table...")
    update_query = text("UPDATE test SET predicted_sales = :predicted_sales WHERE id = :id")
    
    # Zip predictions back to their corresponding database IDs
    update_payload = [
        {"predicted_sales": float(pred), "id": int(row["id"])} 
        for pred, (_, row) in zip(predictions, df.iterrows())
    ]
    
    with engine.begin() as conn:
        conn.execute(update_query, update_payload)
        
    print(f"Batch prediction successfully written to database for {len(df)} records.")

if __name__ == "__main__":
    main()