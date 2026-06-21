from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import mlflow.xgboost
import pandas as pd
import os

app = FastAPI(title="Sales Forecasting API")

# Define the expected input payload based on Rossmann features
class StoreData(BaseModel):
    Store: int
    DayOfWeek: int
    Promo: int
    StateHoliday: int
    SchoolHoliday: int
    Year: int
    Month: int
    Day: int

# Load the model at startup (Ensure you replace RUN_ID with your actual MLflow run ID later)
MODEL_URI = os.getenv("MODEL_URI", "runs:/<YOUR_RUN_ID>/xgboost_model")
try:
    model = mlflow.xgboost.load_model(MODEL_URI)
except Exception as e:
    model = None
    print(f"Warning: Model could not be loaded. Ensure MODEL_URI is correct. Error: {e}")

@app.get("/")
def health_check():
    return {"status": "API is running", "model_loaded": model is not None}

@app.post("/predict")
def predict_sales(data: StoreData):
    if model is None:
        raise HTTPException(status_code=500, detail="Model is not loaded.")
    
    # Convert payload to DataFrame
    input_df = pd.DataFrame([data.model_dump()])
    
    # Predict
    prediction = model.predict(input_df)
    
    return {
        "store_id": data.Store,
        "predicted_sales": float(prediction[0])
    }