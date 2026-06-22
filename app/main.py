import io
import os
import logging
import asyncio
from contextlib import asynccontextmanager

import mlflow.xgboost
import pandas as pd
from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(levelname)s | %(name)s | %(message)s")
logger = logging.getLogger("sales_api")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MLFLOW_URI = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
MODEL_URI  = os.getenv("MODEL_URI", "")

mlflow.set_tracking_uri(MLFLOW_URI)
logger.info("MLflow tracking URI → %s", MLFLOW_URI)
logger.info("Model URI           → %s", MODEL_URI or "<not set>")

# ---------------------------------------------------------------------------
# Model state
# ---------------------------------------------------------------------------
_model            = None
_model_load_error = None

FEATURE_COLUMNS = [
    "Store", "DayOfWeek", "Promo",
    "StateHoliday", "SchoolHoliday",
    "Year", "Month", "Day",
]


def _load_model() -> bool:
    """Single attempt to load the model. Returns True on success."""
    global _model, _model_load_error

    if not MODEL_URI:
        _model_load_error = "MODEL_URI environment variable is not set."
        logger.error(_model_load_error)
        return False

    if "<YOUR_RUN_ID>" in MODEL_URI:
        _model_load_error = "MODEL_URI still contains the placeholder '<YOUR_RUN_ID>'."
        logger.error(_model_load_error)
        return False

    try:
        logger.info("Loading model → %s", MODEL_URI)
        _model = mlflow.xgboost.load_model(MODEL_URI)
        _model_load_error = None
        logger.info("Model loaded successfully.")
        return True

    except Exception as exc:
        _model = None
        _model_load_error = (
            f"{exc}  |  MLflow URI: {MLFLOW_URI}  |  Model URI: {MODEL_URI}"
        )
        logger.warning("Model load failed: %s", exc)
        return False


async def _load_model_with_retry():
    """
    Background task: retries loading the model every 15 s for up to 10 minutes.
    This handles the race where FastAPI starts before the MLflow server is ready.
    """
    for attempt in range(40):           # 40 × 15 s = 10 minutes max
        if _load_model():
            return
        logger.info(
            "MLflow not ready yet (attempt %d/40). Retrying in 15 s...", attempt + 1
        )
        await asyncio.sleep(15)
    logger.error("Gave up loading model after 40 attempts.")


# ---------------------------------------------------------------------------
# App lifespan — starts the retry task in the background
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_load_model_with_retry())
    yield
    task.cancel()


app = FastAPI(
    title="Sales Forecasting API",
    description="XGBoost-based Rossmann store sales forecaster backed by MLflow.",
    version="1.0.0",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Input schema
# ---------------------------------------------------------------------------
class StoreData(BaseModel):
    Store: int
    DayOfWeek: int
    Promo: int
    StateHoliday: int
    SchoolHoliday: int
    Year: int
    Month: int
    Day: int


def _require_model():
    if _model is None:
        raise HTTPException(
            status_code=503,
            detail={
                "error": "Model is not loaded yet.",
                "reason": _model_load_error,
                "fix": "The server retries automatically every 15 s. "
                       "Check logs for progress, or POST /reload-model to force a retry.",
            },
        )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/", summary="Health check")
def health_check():
    return {
        "status": "API is running",
        "model_loaded": _model is not None,
        "mlflow_uri": MLFLOW_URI,
        "model_uri": MODEL_URI or "not set",
        "error": _model_load_error,
    }


@app.post("/reload-model", summary="Force a model reload now")
def reload_model():
    success = _load_model()
    if success:
        return {"status": "Model reloaded successfully.", "model_uri": MODEL_URI}
    raise HTTPException(
        status_code=503,
        detail={"error": "Reload failed.", "reason": _model_load_error},
    )


@app.post("/predict", summary="Predict sales for a single store/day")
def predict_sales(data: StoreData):
    _require_model()
    prediction = _model.predict(pd.DataFrame([data.model_dump()]))
    return {
        "store_id": data.Store,
        "predicted_sales": round(float(prediction[0]), 2),
    }


@app.post("/predict-batch", summary="Predict sales for a CSV of store/day rows")
async def predict_batch(file: UploadFile = File(...)):
    _require_model()

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
