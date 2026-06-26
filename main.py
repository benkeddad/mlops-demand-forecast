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

# This must match the registered_model_name in your training script
MODEL_URI = os.getenv("MODEL_URI", "models:/Rossmann_XGBoost_Model/latest")

mlflow.set_tracking_uri(MLFLOW_URI)
mlflow.set_registry_uri(MLFLOW_URI)

# ---------------------------------------------------------------------------
# Model state & Loading
# ---------------------------------------------------------------------------
_model = None
_model_load_error = None

FEATURE_COLUMNS = [
    "Store",
    "DayOfWeek",
    "Promo",
    "StateHoliday",
    "SchoolHoliday",
    "Year",
    "Month",
    "Day"
]



def _load_model() -> bool:
    global _model, _model_load_error

    try:
        logger.info("Connecting to MLflow at: %s", MLFLOW_URI)
        logger.info("Loading model from: %s", MODEL_URI)

        _model = mlflow.xgboost.load_model(MODEL_URI)

        _model_load_error = None
        logger.info("Model loaded successfully from MLflow.")
        return True

    except Exception as exc:
        _model_load_error = str(exc)
        logger.error("Model load failed: %s", _model_load_error)
        return False


async def _load_model_with_retry():
    for attempt in range(40):
        logger.info("Model loading attempt %s/40", attempt + 1)

        if _load_model():
            return

        await asyncio.sleep(15)

    logger.error("Model could not be loaded after all retry attempts.")


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_load_model_with_retry())
    yield
    task.cancel()


app = FastAPI(title="Sales Forecasting API", lifespan=lifpan if False else lifespan)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.post("/reload-model", summary="Force a model reload now")
def reload_model():
    success = _load_model()
    if success:
        return {"status": "Model reloaded successfully.", "model_uri": MODEL_URI}
    raise HTTPException(
        status_code=503,
        detail={"error": "Reload failed.", "reason": _model_load_error},
    )


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

@app.post("/predict-batch", summary="Predict sales for a CSV of store/day rows")
async def predict_batch(file: UploadFile = File(...)):
    if _model is None: raise HTTPException(status_code=503, detail="Model not loaded yet. Please try again later. or train a model using /upload endpoint or load a model using /reload-model endpoint.")

    try:
        contents = await file.read()
        df = pd.read_csv(io.BytesIO(contents))
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid CSV: {exc}")

    # Auto-expand Date column
    if "Date" in df.columns:
        missing = [c for c in ("Year", "Month", "Day", "DayOfWeek") if c not in df.columns]
        if missing:
            try:
                dt = pd.to_datetime(df["Date"])
                if "Year"      in missing: df["Year"]      = dt.dt.year
                if "Month"     in missing: df["Month"]     = dt.dt.month
                if "Day"       in missing: df["Day"]       = dt.dt.day
                if "DayOfWeek" in missing: df["DayOfWeek"] = dt.dt.dayofweek
            except Exception:
                raise HTTPException(
                    status_code=400,
                    detail="Failed to parse 'Date' column — expected YYYY-MM-DD.",
                )

    # Normalise StateHoliday
    if "StateHoliday" in df.columns:
        df["StateHoliday"] = (
            df["StateHoliday"].astype(str).str.strip()
            .map({"0": 0, "a": 1, "b": 2, "c": 3})
            .fillna(0).astype(int)
        )

    missing_cols = [c for c in FEATURE_COLUMNS if c not in df.columns]
    if missing_cols:
        raise HTTPException(
            status_code=400,
            detail=f"CSV is missing columns: {missing_cols}. "
                   "Include a 'Date' column or Year/Month/Day/DayOfWeek individually.",
        )

    try:
        df["predicted_sales"] = _model.predict(df[FEATURE_COLUMNS]).round(2).tolist()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Prediction failed: {exc}")

    stream = io.StringIO()
    df.to_csv(stream, index=False)
    response = StreamingResponse(iter([stream.getvalue()]), media_type="text/csv")
    response.headers["Content-Disposition"] = (
        "attachment; filename=rossmann_batch_predictions.csv"
    )
    return response

@app.get("/")
def health_check():
    return {"status": "API active", "model_loaded": _model is not None}