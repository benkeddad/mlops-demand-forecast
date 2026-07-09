import os
import sys
import io
import asyncio
import asyncpg
import subprocess
import pandas as pd
from contextlib import asynccontextmanager
from sqlalchemy import create_engine, text
from fastapi import FastAPI, UploadFile, File
from fastapi.responses import RedirectResponse, StreamingResponse
import mlflow.pyfunc
from feast import FeatureStore

# Database and MLflow Configurations
DB_URL = os.getenv("DATABASE_URL", "postgresql://user:password@postgres:5432/rossmann")
MODEL_URI = os.getenv("MODEL_URI", "models:/Rossmann_XGBoost_Model/latest")

_mlflow_uri = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
mlflow.set_tracking_uri(_mlflow_uri)

_model = None
feast_store = FeatureStore(repo_path="feature_repo")

def _load_model() -> bool:
    """Attempts to pull the latest model wrapper from the MLflow registry."""
    global _model
    try:
        _model = mlflow.pyfunc.load_model(MODEL_URI)
        if 'app' in globals():
            app.state.model = _model
        print("Model successfully loaded from MLflow.")
        return True
    except Exception as e:
        print(f"Model loading postponed: {e}")
        return False

async def retry_load_model_on_startup():
    """Background task that retries model loading until successful."""
    while _model is None:
        print("Initial model load failed or pending. Retrying connection to MLflow in 10 seconds...")
        success = _load_model()
        if success:
            break
        await asyncio.sleep(10)

async def handle_train_db_trigger(connection, pid, channel, payload):
    print("Database modification noticed on 'train' table. Activating Prefect Pipeline...")
    pipeline_script = os.path.normpath(os.path.join("pipelines", "training_pipeline.py"))
    
    proc = await asyncio.create_subprocess_exec(sys.executable, pipeline_script)
    await proc.wait()
    
    _load_model()

async def handle_predict_db_trigger(connection, pid, channel, payload):
    current_model = app.state.model if hasattr(app, 'state') and hasattr(app.state, 'model') else _model
    
    if current_model is None:
        print("Prediction aborted: No model is currently loaded inside application memory.")
        return
        
    rows = await connection.fetch('SELECT id, store FROM test WHERE predicted_sales IS NULL')
    if not rows:
        return

    print(f"Batch prediction triggered. Processing {len(rows)} new rows...")

    entity_rows = [{"entity_id": int(row["store"])} for row in rows]

    feature_response = feast_store.get_online_features(
        features=[
            "rossmann_features:Store", "rossmann_features:DayOfWeek", "rossmann_features:Promo",
            "rossmann_features:StateHoliday", "rossmann_features:SchoolHoliday",
            "rossmann_features:Year", "rossmann_features:Month", "rossmann_features:Day"
        ],
        entity_rows=entity_rows
    ).to_df()

    # Create a copy to safely transform features
    features_only = feature_response[["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]].copy()
    
    # Map categorical holiday strings back to integers
    holiday_map = {"0": 0, "a": 1, "b": 2, "c": 3}
    features_only["StateHoliday"] = (
        features_only["StateHoliday"].astype(str).str.strip()
        .map(holiday_map).fillna(0).astype(int)
    )

    # Coerce everything to int to align with your XGBoost training matrix
    features_only = features_only.apply(pd.to_numeric, errors="coerce").fillna(0).astype(int)
    
    # Run batch inference
    predictions = current_model.predict(features_only)
    
    update_data = [(float(pred), int(row["id"])) for pred, row in zip(predictions, rows)]
    
    await connection.executemany(
        'UPDATE test SET predicted_sales = $1 WHERE id = $2', 
        update_data
    )
    print(f"Batch prediction successfully written to database for {len(rows)} records.")
    
async def run_postgres_event_loop():
    while True:
        try:
            conn = await asyncpg.connect(DB_URL)
            await conn.add_listener('train_changed', handle_train_db_trigger)
            await conn.add_listener('test_inserted', handle_predict_db_trigger)
            print("Successfully bound persistent notification listeners to PostgreSQL channels.")
            while True:
                await asyncio.sleep(5)
        except Exception as err:
            print(f"Database connection dropped ({err}). Retrying connection loop in 5 seconds...")
            await asyncio.sleep(5)

@asynccontextmanager
async def lifespan(app: FastAPI):
    if not _load_model():
        asyncio.create_task(retry_load_model_on_startup())
        
    listener_worker = asyncio.create_task(run_postgres_event_loop())
    yield
    listener_worker.cancel()

app = FastAPI(title="Event-Driven Demand Forecast API", lifespan=lifespan)
app.state.model = _model

@app.get("/health")
def health():
    current_model = app.state.model if hasattr(app, 'state') and hasattr(app.state, 'model') else _model
    return {"status": "active", "model_ready": current_model is not None}

@app.get("/", include_in_schema=False)
def redirect_to_docs():
    return RedirectResponse(url="/docs")