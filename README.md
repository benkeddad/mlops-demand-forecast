# MLOps Demand Forecast

An end-to-end MLOps pipeline that trains and serves a sales-forecasting model (Rossmann store sales) using XGBoost. It combines a versioned data/training pipeline, experiment tracking, and a live prediction API, and it can run either directly on Windows or fully inside Docker.

## What it does

- **Predicts daily store sales** from features like store ID, day of week, promo status, and holiday flags, using an XGBoost regression model.
- **Versions the training pipeline with DVC** (`dvc.yaml`): raw `train.csv` → `ingest` (clean) → `featurize` (build model features) → `train` (fit XGBoost, log to MLflow).
- **Orchestrates that pipeline with Prefect** (`pipelines/training_pipeline.py`), which wraps the three DVC stages in a tracked flow.
- **Tracks experiments and hosts a model registry with MLflow** — every run logs its params/metrics and registers the model as `Rossmann_XGBoost_Model`.
- **Serves predictions with FastAPI** (`app/main.py`), which loads the latest registered model and exposes a REST API.
- **Auto-retrains itself**: on startup, the API checks the content hash of `train.csv`. If the data changed, it kicks off the full Prefect/DVC pipeline; if the model is simply missing, it runs `src/train.py` directly. Uvicorn watches the training-data folder, so dropping in a new `train.csv` triggers this automatically.
- **Monitors data drift** with Evidently (`monitoring/drift.py`) — a standalone script you run manually to compare reference vs. live data and produce an HTML report.
- **Ships as a Docker Compose stack** (`docker-compose.yaml` + `Dockerfile`) with three services: `mlflow`, `prefect`, and `api`.

### API endpoints (`app/main.py`)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | Health check — reports whether a model is currently loaded |
| `POST` | `/upload` | Upload a new `train.csv` to the training-data folder |
| `POST` | `/predict-batch` | Upload a CSV of store/day rows, get back a CSV with a `predicted_sales` column |
| `POST` | `/reload-model` | Force a reload of the latest model from the MLflow registry |

## Which `.bat` file to run

The repo has two entry points. They solve different problems — pick based on what you're trying to do.

### `run_stack.bat` — local Windows development, no Docker

**Use this when** you're actively developing or debugging on your Windows machine, want to point the app at any folder on disk (via a native folder picker), and want to see the MLflow and Prefect UIs in their own terminal windows.

What it does:
1. Creates/activates a `venv` and installs `requirements.txt` if needed.
2. Opens a Windows folder-picker dialog so you choose the folder containing your `train.csv`.
3. Runs `dvc init --no-scm` and `dvc pull`.
4. Starts the MLflow server (port `5000`) and Prefect server (port `4200`), each in its own terminal window.
5. Waits 30 seconds for both to boot, sets `MLFLOW_TRACKING_URI` / `PREFECT_API_URL` for the session.
6. Starts Uvicorn (the FastAPI app) on port `8000`, watching your chosen folder so any change to `train.csv` triggers a reload.

Run it from the repo root:
```bat
run_stack.bat
```
Requires: Python 3.9+ on Windows. Docker is **not** needed for this path.

### `dockerize.bat` — full containerized stack

**Use this when** you want to build and run the whole stack (MLflow + Prefect + API) as Docker containers — for a production-like test, deployment, or handing the project to a teammate — without disturbing your local DVC/MLflow state.

What it does:
1. Temporarily backs up your local `.dvc/`, `dvc.lock`, `mlartifacts/`, and `mlruns/`.
2. Initializes a clean, temporary DVC config so a fresh one gets baked into the Docker image.
3. Stops any running containers (`docker-compose down -v`) and builds the images (`docker-compose build`).
4. Restores your original local `.dvc/`, `dvc.lock`, `mlartifacts/`, and `mlruns/` from the backup.
5. Starts the containers (`docker-compose up -d`), waits for them to boot, then runs a final local `dvc pull` to resync.

Run it from the repo root:
```bat
dockerize.bat
```
Requires: Docker Desktop running. After it finishes:
- API → http://localhost:8000
- MLflow UI → http://localhost:5000
- Prefect UI → http://localhost:4200

### Quick reference

| You want to... | Run |
|---|---|
| Iterate on code locally with fast feedback, no Docker overhead | `run_stack.bat` |
| Run the full stack in containers, closer to how it'd deploy | `dockerize.bat` |

## Prerequisites

- Windows (both scripts are `.bat` files)
- Python 3.9+ — for `run_stack.bat`, and matches the `python:3.9-slim` base image used in Docker
- Docker Desktop — for `dockerize.bat` only
- Git

## Project structure

```
mlops-demand-forecast/
├── app/
│   └── main.py               # FastAPI app: serving, upload, auto-retrain trigger
├── pipelines/
│   └── training_pipeline.py  # Prefect flow wrapping the DVC stages
├── src/
│   ├── data.py                # ingest: load raw CSV -> clean_data.csv
│   ├── features.py            # featurize: build the 8 model features
│   ├── model.py                # XGBoost model definition
│   ├── train.py                # train stage: fit model, log/register to MLflow
│   └── evaluate.py            # RMSPE metric
├── monitoring/
│   └── drift.py                # Evidently data-drift HTML report (run manually)
├── data/
│   ├── raw/train.csv           # Rossmann-format training data
│   └── processed/              # DVC-generated intermediate files
├── dvc.yaml                    # DVC pipeline stages: ingest -> featurize -> train
├── Dockerfile                  # API service image
├── docker-compose.yaml         # mlflow + prefect + api services
├── run_stack.bat                # Local Windows dev entry point
├── dockerize.bat                 # Dockerized stack entry point
└── requirements.txt
```

## Data format

The pipeline expects the classic Rossmann Store Sales columns: `Store`, `DayOfWeek`, `Date`, `Sales`, `Customers`, `Open`, `Promo`, `StateHoliday`, `SchoolHoliday`. `Date` is expanded into `Year`/`Month`/`Day`, and `Customers`/`Open`/`Id` are dropped since they aren't available at inference time. The model itself is trained and served on 8 features: `Store`, `DayOfWeek`, `Promo`, `StateHoliday`, `SchoolHoliday`, `Year`, `Month`, `Day`.

## Getting started

```bash
git clone https://github.com/benkeddad/mlops-demand-forecast.git
cd mlops-demand-forecast
```

Then run either `run_stack.bat` (local dev) or `dockerize.bat` (Docker), depending on your need above.
