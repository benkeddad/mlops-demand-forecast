from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import mlflow.xgboost
import pandas as pd
import io
import os

app = FastAPI(title="Sales Forecasting API")

# ADD THIS LINE HERE: Tell MLflow to use the tracking network address
mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://mlflow_server:5000"))

# Define the expected input payload for single predictions
class StoreData(BaseModel):
    Store: int
    DayOfWeek: int
    Promo: int
    StateHoliday: int
    SchoolHoliday: int
    Year: int
    Month: int
    Day: int

# Load the model at startup
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

@app.post("/predict-batch")
async def predict_batch(file: UploadFile = File(...)):
    if model is None:
        raise HTTPException(status_code=500, detail="Model is not loaded.")
    
    # 1. Read the uploaded CSV bytes into a DataFrame
    try:
        contents = await file.read()
        df = pd.read_csv(io.BytesIO(contents))
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid CSV file. Error: {e}")
    
    # 2. Smart Feature Engineering: If the CSV has a raw 'Date' column, split it automatically
    if "Date" in df.columns and not all(col in df.columns for col in ["Year", "Month", "Day"]):
        try:
            datetime_col = pd.to_datetime(df["Date"])
            df["Year"] = datetime_col.dt.year
            df["Month"] = datetime_col.dt.month
            df["Day"] = datetime_col.dt.day
        except Exception:
            raise HTTPException(status_code=400, detail="Failed to parse 'Date' column. Ensure format is YYYY-MM-DD.")

    # 3. Handle StateHoliday conversion to clean integers matching your StoreData expectations
    if "StateHoliday" in df.columns:
        df["StateHoliday"] = df["StateHoliday"].astype(str).str.strip()
        df["StateHoliday"] = df["StateHoliday"].map({"0": 0, "a": 1, "b": 2, "c": 3}).fillna(0).astype(int)

    # 4. Enforce the exact 8 features and their ordering required by your XGBoost model
    feature_columns = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
    
    missing_cols = [col for col in feature_columns if col not in df.columns]
    if missing_cols:
        raise HTTPException(
            status_code=400, 
            detail=f"Uploaded CSV is missing required columns. Must contain either a 'Date' column or individual features: {missing_cols}"
        )
    
    # Extract only the features the model knows how to read
    input_df = df[feature_columns]
    
    # 5. Generate batch predictions
    try:
        predictions = model.predict(input_df)
        df["predicted_sales"] = predictions.tolist()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Model prediction failed: {e}")
    
    # 6. Stream the updated DataFrame back to the user as a file download
    stream = io.StringIO()
    df.to_csv(stream, index=False)
    
    response = StreamingResponse(
        iter([stream.getvalue()]),
        media_type="text/csv"
    )
    response.headers["Content-Disposition"] = "attachment; filename=rossmann_batch_predictions.csv"
    
    return response