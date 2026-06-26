@echo off
echo Starting MLOps Stack...

echo 📦 Starting MLflow...
start cmd /k "call .venv\Scripts\activate.bat && mlflow server --host 127.0.0.1 --port 5000"

echo 🔮 Starting Prefect...
start cmd /k "call .venv\Scripts\activate.bat && prefect server start --host 127.0.0.1 --port 4200"

:: Wait for 3 seconds to let backend initialize
timeout /t 3 /nobreak > NUL

echo ⚡ Starting FastAPI...
call .venv\Scripts\activate.bat
set MLFLOW_TRACKING_URI=http://127.0.0.1:5000
set PREFECT_API_URL=http://127.0.0.1:4200/api
uvicorn main:app --host 127.0.0.1 --port 8000 --reload