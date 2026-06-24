import io
import os
import sys
import logging
import asyncio
import subprocess
import shutil
from contextlib import asynccontextmanager

import mlflow.xgboost
import pandas as pd
from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Logging & Config
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(levelname)s | %(name)s | %(message)s")
logger = logging.getLogger("sales_api")

MLFLOW_URI = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
MODEL_URI  = os.getenv("MODEL_URI", "")

mlflow.set_tracking_uri(MLFLOW_URI)

# ---------------------------------------------------------------------------
# Model state & Loading
# ---------------------------------------------------------------------------
_model = None
_model_load_error = None
FEATURE_COLUMNS = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]

def _load_model() -> bool:
    global _model, _model_load_error
    try:
        _model = mlflow.xgboost.load_model(MODEL_URI)
        _model_load_error = None
        return True
    except Exception as exc:
        _model_load_error = str(exc)
        return False

async def _load_model_with_retry():
    for attempt in range(40):
        if _load_model(): return
        await asyncio.sleep(15)

@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_load_model_with_retry())
    yield
    task.cancel()

app = FastAPI(title="Sales Forecasting API", lifespan=lifespan)

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

import sys # <--- Make sure you have this import at the top of main.py

@app.post("/upload", summary="Upload new data and trigger DVC/Prefect training")
async def upload_new_data(file: UploadFile = File(...)):
    """Saves raw data and triggers the background training orchestration."""
    target_path = os.path.join("data", "raw", "train.csv")
    
    # 1. Save the uploaded file
    try:
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        with open(target_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        logger.info("File saved to %s", target_path)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"File save error: {exc}")

    # 2. Trigger Prefect Orchestrator 
    # sys.executable ensures we use the Python inside your active venv
    pipeline_script = os.path.join("pipelines", "training_pipeline.py")
    
    try:
        logger.info("Triggering background training using: %s", sys.executable)
        
        # We use sys.executable to ensure the sub-process has access to 'prefect'
        subprocess.Popen([sys.executable, pipeline_script])
        
        return {
            "status": "Training pipeline triggered in background.",
            "pipeline_path": pipeline_script
        }
    except Exception as exc:
        logger.error("Orchestration failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Orchestration failed: {exc}")

@app.post("/predict-batch", summary="Predict sales from CSV")
async def predict_batch(file: UploadFile = File(...)):
    if _model is None: raise HTTPException(status_code=503, detail="Model loading...")
    
    contents = await file.read()
    df = pd.read_csv(io.BytesIO(contents))
    
    # Simple feature prep logic (matching your features.py logic)
    if "Date" in df.columns:
        dt = pd.to_datetime(df["Date"])
        df["Year"], df["Month"], df["Day"] = dt.dt.year, dt.dt.month, dt.dt.day
    
    df["predicted_sales"] = _model.predict(df[FEATURE_COLUMNS]).round(2).tolist()
    
    stream = io.StringIO()
    df.to_csv(stream, index=False)
    return StreamingResponse(iter([stream.getvalue()]), media_type="text/csv")

@app.get("/")
def health_check():
    return {"status": "API active", "model_loaded": _model is not None}