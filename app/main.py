import os
import sys
import logging
import asyncio
import subprocess
from contextlib import asynccontextmanager
import mlflow.pyfunc
import pandas as pd
from fastapi import FastAPI, HTTPException
import asyncpg
from feast import FeatureStore
from fastapi.responses import StreamingResponse, RedirectResponse

# 1. Get the path to 'project_folder' (one level up from 'app') and add it to Python's search path
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if project_root not in sys.path:
    sys.path.append(project_root)

# 2. Now you can import from the 'src' folder directly
from src.features import build_features

# ---------------------------------------------------------------------------
# Config & State
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(levelname)s | %(name)s | %(message)s")
logger = logging.getLogger("sales_api")

MLFLOW_URI = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
MODEL_URI = os.getenv("MODEL_URI", "models:/Rossmann_XGBoost_Model/latest")
DB_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@localhost:5432/rossmann")

mlflow.set_tracking_uri(MLFLOW_URI)
_model = None
feast_store = FeatureStore(repo_path="feature_repo")

# ---------------------------------------------------------------------------
# The Shared Prediction Logic (Source of Truth)
# ---------------------------------------------------------------------------
async def perform_batch_prediction():
    if _model is None:
        logger.warning("Prediction skipped: No model loaded.")
        return

    # 1. Connect directly
    connection = await asyncpg.connect(DB_URL)
    
    try:
        # 2. Fetch rows (Now fetching all feature columns instead of just store entity ID)
        rows = await connection.fetch(
            'SELECT id, store, date, dayofweek, promo, stateholiday, schoolholiday FROM test WHERE predicted_sales IS NULL'
        )
        
        if not rows:
            logger.info("No new rows to predict.")
            return

        logger.info(f"Performing batch prediction for {len(rows)} rows...")

        # 3. Convert raw asyncpg records directly to a Pandas DataFrame
        raw_data = [dict(row) for row in rows]
        df = pd.DataFrame(raw_data)

        # 4. Map lowercase Postgres columns to the expected capitalized names
        column_mapping = {
            "store": "Store",
            "dayofweek": "DayOfWeek",
            "promo": "Promo",
            "stateholiday": "StateHoliday",
            "schoolholiday": "SchoolHoliday",
            "date": "Date"
        }
        df_renamed = df.rename(columns=column_mapping)

        # 5. Process temporal features locally (Bypassing Feast Online Store temporal limitations)
        processed_df = build_features(df_renamed)

        # 6. Strictly enforce column order (The Fix)
        # Defining the list here ensures the model sees features in the exact same 
        # order it was trained on.
        feature_cols = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
        
        # Slice and copy in one single step to prevent DataFrame re-indexing issues
        features_only = processed_df[feature_cols].copy()
        
        # Numeric conversion
        features_only = features_only.apply(pd.to_numeric, errors="coerce").fillna(0).astype(int)
        
        # 7. Predict
        predictions = _model.predict(features_only)
        
        # 8. Check if predictions are all the same (The Debugger)
        if len(set(predictions)) == 1:
            logger.warning(f"WARNING: Model outputted the same value ({predictions[0]}) for all {len(rows)} rows.")
            logger.info(f"Sample features passed to model:\n{features_only.iloc[0].to_dict()}")

        # 9. Update DB
        update_data = [(float(pred), int(row["id"])) for pred, row in zip(predictions, rows)]
        
        await connection.executemany(
            'UPDATE test SET predicted_sales = $1 WHERE id = $2', 
            update_data
        )
        logger.info(f"Batch prediction written for {len(rows)} records.")

    except Exception as e:
        logger.error(f"Prediction failed: {e}")
        
    finally:
        # Always close to prevent connection leaks
        await connection.close()

# ---------------------------------------------------------------------------
# Loaders & Triggers
# ---------------------------------------------------------------------------
def _load_model() -> bool:
    global _model
    try:
        _model = mlflow.pyfunc.load_model(MODEL_URI)
        logger.info("Model loaded successfully.")
        return True
    except Exception as e:
        logger.error(f"Load failed: {e}")
        return False

async def wait_and_reload(process):
    await asyncio.to_thread(process.wait)
    logger.info("Training finished. Reloading model...")
    if _load_model():
        logger.info("Triggering post-training batch prediction...")
        # Fire the prediction in the background
        asyncio.create_task(perform_batch_prediction())

async def handle_train_db_trigger(connection, pid, channel, payload):

    logger.info("Training trigger received.")
    script = os.path.normpath(os.path.join("pipelines", "training_pipeline.py"))
    try:
        # Start the process
        process = subprocess.Popen([sys.executable, script])
        asyncio.create_task(wait_and_reload(process))

    except Exception as exc:
        logger.error("Orchestration failed on SQL trigger: %s", exc)

async def handle_predict_db_trigger(connection, pid, channel, payload):
    # This just delegates to the shared function
    await perform_batch_prediction()

async def run_postgres_event_loop():
    while True:
        try:
            conn = await asyncpg.connect(DB_URL)
            await conn.add_listener('train_changed', handle_train_db_trigger)
            await conn.add_listener('test_inserted', handle_predict_db_trigger)
            while True: await asyncio.sleep(5)
        except Exception as err:
            logger.error(f"DB connection lost: {err}")
            await asyncio.sleep(5)

@asynccontextmanager
async def lifespan(app: FastAPI):
    _load_model()
    asyncio.create_task(run_postgres_event_loop())
    yield

app = FastAPI(title="Sales Forecasting API", lifespan=lifespan)

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
        detail={"error": "Reload failed.", "reason": "Model loading encountered an error"},
    )

@app.get("/predict/realtime/{store_id}", summary="Real-time live prediction using Feast + Redis")
async def predict_realtime(store_id: int):
    """
    Demonstrates Live Serving Path (Online):
    Retrieves the latest pre-computed features for a single store from Redis 
    via Feast in <10ms, then runs live model inference.
    """
    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded.")
    
    try:
        # 1. Look up the latest feature snapshot from the Redis Online Store
        # Since Feast's SDK is synchronous, we run it in a thread to keep FastAPI async
        entity_rows = [{"entity_id": store_id}]
        
        logger.info(f"Retrieving online features from Redis for Store {store_id}...")
        feature_response = await asyncio.to_thread(
            feast_store.get_online_features,
            features=[
                "rossmann_features:Store", "rossmann_features:DayOfWeek", "rossmann_features:Promo",
                "rossmann_features:StateHoliday", "rossmann_features:SchoolHoliday",
                "rossmann_features:Year", "rossmann_features:Month", "rossmann_features:Day"
            ],
            entity_rows=entity_rows
        )
        
        feature_df = feature_response.to_df()
        
        # 2. Check if the store exists in the Redis cache
        if feature_df.empty or pd.isna(feature_df["Store"].iloc[0]):
            raise HTTPException(
                status_code=404, 
                detail=f"Store {store_id} not found in Redis. Run 'feast materialize-incremental' first."
            )

        # 3. Clean and align features exactly like the training setup
        feature_cols = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
        features_only = feature_df[feature_cols].copy()
        
        holiday_map = {"0": 0, "a": 1, "b": 2, "c": 3}
        features_only["StateHoliday"] = (
            features_only["StateHoliday"].astype(str).str.strip()
            .map(holiday_map).fillna(0).astype(int)
        )
        features_only = features_only.apply(pd.to_numeric, errors="coerce").fillna(0).astype(int)
        
        # 4. Run real-time inference on the fetched features
        prediction = _model.predict(features_only)[0]
        
        return {
            "store_id": store_id,
            "predicted_sales": float(prediction),
            "retrieved_features": features_only.iloc[0].to_dict(),
            "latency_ms": "Ultra-low (<10ms)",
            "source": "Feast Online Store (Redis Cache)"
        }
        
    except HTTPException as he:
        raise he
    except Exception as e:
        logger.error(f"Real-time prediction failed: {e}")
        raise HTTPException(status_code=500, detail=f"Inference error: {str(e)}")

@app.get("/health", summary="Check API and Model status")
def health_check():
    return {"status": "API active", "model_loaded": _model is not None}

@app.get("/", include_in_schema=False)
def redirect_to_docs():
    # This automatically sends anyone visiting the main URL straight to the dashboard
    return RedirectResponse(url="/docs")