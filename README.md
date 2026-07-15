# MLOps Demand Forecasting Platform — Rossmann Store Sales

[![CI](https://github.com/benkeddad/mlops-demand-forecast/actions/workflows/ci.yml/badge.svg)](https://github.com/benkeddad/mlops-demand-forecast/actions/workflows/ci.yml)
![Python](https://img.shields.io/badge/python-3.9-blue?logo=python&logoColor=white)
![XGBoost](https://img.shields.io/badge/model-XGBoost-006400)
![MLflow](https://img.shields.io/badge/tracking-MLflow-0194E2)
![Prefect](https://img.shields.io/badge/orchestration-Prefect%202-024DFD)
![DVC](https://img.shields.io/badge/data%20versioning-DVC-945DD6)
![Feast](https://img.shields.io/badge/feature%20store-Feast-FF5A5F)
![Kubernetes](https://img.shields.io/badge/orchestration-Kubernetes%20(K3s)-326CE5?logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white)
![Docker](https://img.shields.io/badge/containers-Docker-2496ED?logo=docker&logoColor=white)

A closed-loop, event-driven demand forecasting system for Rossmann retail sales, built to demonstrate a **complete, production-shaped MLOps stack** rather than a notebook-to-API demo. Writing a row to Postgres is enough to trigger feature materialization, retraining, model registration, and live model hot-swap — with no cron jobs, no polling, and no manual steps.

The system ships with **two independent, fully automated deployment paths**: a Docker Compose stack for local iteration, and a Terraform-provisioned Kubernetes (K3s) deployment for a production-representative environment — both running the exact same five-service architecture.

> This README documents the `terraform_and_k3s_integrated` branch, which layers the Kubernetes/Terraform deployment path on top of the base Docker Compose stack.

---

## Table of Contents

1. [Architecture at a Glance](#architecture-at-a-glance)
2. [Tech Stack Matrix](#tech-stack-matrix)
3. [Repository Structure](#repository-structure)
4. [Core MLOps Capabilities](#core-mlops-capabilities)
5. [Deployment Architectures](#deployment-architectures)
6. [Infrastructure-as-Code Deep Dive](#infrastructure-as-code-deep-dive)
7. [One-Click Orchestration (`run_all.bat`)](#one-click-orchestration-run_allbat)
8. [Notable Engineering Problems Solved](#notable-engineering-problems-solved)
9. [Prerequisites & Environment Setup](#prerequisites--environment-setup)
10. [Quickstart](#quickstart)
11. [API Reference](#api-reference)
12. [Configuration Reference](#configuration-reference)
13. [CI/CD](#cicd)
14. [Troubleshooting](#troubleshooting)
15. [Security & Production-Readiness Notes](#security--production-readiness-notes)
16. [Roadmap](#roadmap)
17. [About](#about)

---

## Architecture at a Glance

```mermaid
flowchart LR
    subgraph Storage["Storage & Event Bus"]
        PG[(PostgreSQL 15<br/>train / test tables)]
        RD[(Redis 7<br/>Feast Online Store)]
    end

    subgraph Track["Tracking & Orchestration"]
        MLF[MLflow<br/>Tracking Server + Model Registry]
        PRF[Prefect Server<br/>Rossmann-Enterprise-Pipeline]
    end

    subgraph Pipe["DVC Pipeline"]
        ING[ingest<br/>src/data.py]
        FEA[featurize<br/>src/features.py]
        TRN[train<br/>src/train.py]
        ING --> FEA --> TRN
    end

    FS{Feast Feature Store}
    API[FastAPI + Uvicorn<br/>rossmann-api]

    PG -- "LISTEN/NOTIFY\ntrain_changed / test_inserted" --> API
    API -- "subprocess spawn" --> PRF
    PRF --> ING
    ING -- "reads train table" --> PG
    FEA -- "feast apply / materialize" --> FS
    FS -- offline reads --> PG
    FS -- online writes --> RD
    TRN -- "log_model + register" --> MLF
    API -- "pyfunc.load_model(latest)" --> MLF
    API -- "batch predict, writes back" --> PG
    API -- "GET /predict/realtime" --> FS
    FS -- online reads --> RD
```

**The core idea:** Postgres is not just a data store here — it doubles as a lightweight event bus via `LISTEN/NOTIFY` triggers, so the whole retrain → register → reload → rescore cycle happens autonomously and is fully observable through MLflow and Prefect.

---

## Tech Stack Matrix

| MLOps Discipline | Tool | Role in this project |
|---|---|---|
| Data & pipeline versioning | **DVC** (`>=3.50.0`) | Owns caching/reproducibility for the `ingest → featurize → train` stages; each stage is content-hashed and only reruns when its declared deps change |
| Workflow orchestration | **Prefect 2** (`2.14`, self-hosted server) | Wraps the DVC stages as a tracked, retryable flow (`Rossmann-Enterprise-Pipeline`) with a UI for run history |
| Feature store (offline + online) | **Feast** (`postgres`, `redis` extras) | Guarantees training/serving feature parity: Postgres as the offline source of truth, Redis as the low-latency online cache |
| Experiment tracking & model registry | **MLflow** (`>=2.10.0`) | Logs params/metrics/lineage per run, and versions the model under a named registry entry the API resolves at load time |
| Model | **XGBoost** (`XGBRegressor`) | Gradient-boosted regression tree ensemble forecasting daily store sales |
| Model serving | **FastAPI** + **Uvicorn** (async) | Exposes real-time and batch inference, plus operational endpoints, with a non-blocking event loop |
| Relational storage / event bus | **PostgreSQL 15** | System of record for `train`/`test`, and source of `pg_notify` events that drive the whole pipeline |
| Online feature cache | **Redis 7** | Backs Feast's online store for sub-10ms feature lookups |
| Data drift monitoring | **Evidently** (`>=0.4.0`) | `DataDriftPreset` HTML reports comparing reference vs. live data distributions |
| Containerization | **Docker** + **Docker Compose** | Single-image packaging (`Dockerfile`) and a 5-service local dev stack (`docker-compose.yaml`) |
| Container orchestration | **Kubernetes (K3s)** | Lightweight, single-binary Kubernetes distribution used as the production-representative runtime |
| Infrastructure as Code | **Terraform** (`hashicorp/kubernetes` provider, `~>2.24`) | Declaratively provisions every Deployment, Service, PVC, and ConfigMap the stack needs |
| CI | **GitHub Actions** | Lints (`flake8`) and test-gates every push/PR to `main` |
| DB access (async) | **asyncpg** | Powers the FastAPI event listener and low-latency batch writes |
| DB access (sync/ORM) | **SQLAlchemy** + **psycopg2/psycopg** | Used by the DVC-stage scripts and Feast's Postgres offline store |
| Numerical / data stack | **pandas**, **NumPy**, **scikit-learn**, **PyArrow** | DataFrame transforms, train/val split, and fast Parquet I/O between pipeline stages |

---

## Repository Structure

```
mlops-demand-forecast/
├── app/
│   └── main.py               # FastAPI app: lifespan hooks, event listeners, inference routes
├── src/
│   ├── data.py                # DVC "ingest" stage — pulls `train` table from Postgres → parquet
│   ├── features.py            # DVC "featurize" stage — builds features, applies + materializes Feast
│   ├── model.py                # XGBRegressor factory
│   ├── train.py                # DVC "train" stage — trains, evaluates, logs + registers to MLflow
│   ├── evaluate.py             # RMSPE metric (zero-sales masked)
│   ├── predict_initial.py      # One-shot batch scoring pass run at container bootstrap
│   └── seed_db.py              # Idempotent CSV → Postgres loader for train/test tables
├── pipelines/
│   └── training_pipeline.py    # Prefect flow wrapping the three DVC stages as tasks
├── feature_repo/
│   ├── feature_store.yaml      # Feast project config — Postgres offline / Redis online
│   ├── features.py             # Entity + FeatureView + PostgreSQLSource definitions
│   └── materialize.py          # Standalone wide-window materialization utility
├── monitoring/
│   └── drift.py                 # Evidently data-drift HTML report generator
├── terraform/
│   └── main.tf                  # Full K8s resource graph: Postgres/Redis/MLflow/Prefect/API
├── .github/workflows/ci.yml    # Lint + test GitHub Actions workflow
├── init.sql                     # Schema + LISTEN/NOTIFY trigger definitions (the event bus)
├── Dockerfile                   # Single image for the API + pipeline code
├── entrypoint.sh                # Container bootstrap sequence (see below)
├── docker-compose.yaml         # Local 5-service stack definition
├── dockerize.bat                # Rebuild/restart helper for the Compose path
├── run_all.bat                  # One-click WSL2 → K3s → Terraform deployment
├── install_terraform.sh        # Idempotent Terraform installer for the WSL Ubuntu shell
├── dvc.yaml                     # DVC stage graph (ingest → featurize → train)
└── requirements.txt              # Full Python dependency set
```

---

## Core MLOps Capabilities

### 1. Data & Pipeline Versioning — DVC

`dvc.yaml` defines a three-stage, dependency-tracked pipeline:

```yaml
stages:
  ingest:      python src/data.py        # deps: src/data.py            → clean_data.parquet
  featurize:   python src/features.py    # deps: clean_data.parquet     → train_features.parquet
  train:       python src/train.py       # deps: train_features.parquet → registered MLflow model
```

Each stage is only re-executed when its declared dependencies actually change, giving the pipeline reproducible, cache-aware reruns instead of "just run everything every time." DVC is deliberately kept in charge of *what* needs to rerun, while Prefect (below) is kept in charge of *when* and *how it's observed*.

### 2. Workflow Orchestration — Prefect

`pipelines/training_pipeline.py` wraps the three DVC stages as a Prefect flow:

```python
@flow(name="Rossmann-Enterprise-Pipeline")
def ml_training_pipeline():
    dvc_ingest()     # @task, retries=1
    dvc_featurize()  # @task
    dvc_train()      # @task
```

This intentionally layers Prefect *on top of* DVC rather than replacing it: DVC gives content-hash caching and stage-level reproducibility; Prefect gives retries, run history, and a queryable UI (`http://localhost:4200`) for every pipeline execution — a common production pattern for teams that want orchestration observability without giving up file-level pipeline caching.

### 3. Feature Store — Feast (Offline/Online Parity)

`feature_repo/features.py` defines a single entity (`entity_id`, aliased from `store`) and a `FeatureView` (`rossmann_features`) sourced from a live SQL query against Postgres:

```python
rossmann_source = PostgreSQLSource(
    query="""
        SELECT store AS entity_id, store AS "Store", dayofweek AS "DayOfWeek",
               promo AS "Promo", stateholiday AS "StateHoliday",
               schoolholiday AS "SchoolHoliday",
               EXTRACT(YEAR FROM date)::INTEGER AS "Year",
               EXTRACT(MONTH FROM date)::INTEGER AS "Month",
               EXTRACT(DAY FROM date)::INTEGER AS "Day",
               date AS event_timestamp
        FROM train
    """,
    timestamp_field="event_timestamp",
)
```

- **Offline store:** Postgres — used for point-in-time-correct historical feature retrieval during training.
- **Online store:** Redis — used for millisecond-latency feature lookups at inference time.
- **TTL:** 3650 days — set deliberately wide because the Rossmann dataset's historical range (2013–2015) would otherwise fall outside Feast's default lookback window (see [Notable Engineering Problems Solved](#notable-engineering-problems-solved)).

This is the textbook feature-store guarantee: the *same* feature definitions and transformation logic serve both the training pipeline and the real-time API, eliminating training/serving skew.

### 4. Experiment Tracking & Model Registry — MLflow

`src/train.py` logs a fully lineage-tracked run for every training pass:

```python
with mlflow.start_run():
    dataset = mlflow.data.from_pandas(processed_df, source=processed_data_path)
    mlflow.log_input(dataset, context="training")           # dataset lineage

    model = get_model(n_estimators=150, max_depth=8)
    model.fit(X_train, y_train)

    mlflow.log_param("model_type", "XGBRegressor")
    mlflow.log_metric("val_rmspe", calculate_rmspe(y_val.values, model.predict(X_val)))

    mlflow.xgboost.log_model(
        xgb_model=model,
        artifact_path="xgboost_model",
        registered_model_name="Rossmann_XGBoost_Model",   # → MLflow Model Registry
    )
```

Every run captures **parameters, metrics, and the exact dataset used** (via `mlflow.log_input`), and every successful run is pushed straight into the **Model Registry** rather than just the tracking store — so `models:/Rossmann_XGBoost_Model/latest` always resolves to the newest trained version without any manual "promote to production" step.

### 5. Model — XGBoost Regression

`src/model.py` wraps `xgboost.XGBRegressor` (`objective='reg:squarederror'`). Training uses `n_estimators=150, max_depth=8`; evaluation uses **RMSPE** (Root Mean Square Percentage Error) — the actual metric used in the original Kaggle Rossmann competition — computed in `src/evaluate.py` with zero-sales days masked out to avoid division-by-zero distortion.

### 6. Model Serving — FastAPI with Dual Inference Paths

`app/main.py` exposes **two distinct inference paths**, deliberately modeling the two inference patterns almost every production forecasting system needs:

| Path | Endpoint | Feature source | Use case |
|---|---|---|---|
| **Batch** | internal (`perform_batch_prediction`, triggered by DB events or `/reload-model`) | Direct Postgres query + local `build_features()` | Scoring large backlogs of `test` rows; bypasses Feast's temporal materialization window entirely, since freshly inserted rows may not be materialized yet |
| **Real-time** | `GET /predict/realtime/{store_id}` | Feast **online store** (Redis) | Single-entity, sub-10ms feature retrieval + live inference — the pattern used for request-time serving |

The batch path strictly re-orders and type-casts columns (`["Store","DayOfWeek","Promo","StateHoliday","SchoolHoliday","Year","Month","Day"]`) to guarantee the exact schema the model was trained on — a deliberate defense against silent feature-order mismatches, a classic source of "the model always predicts the same value" bugs.

### 7. Event-Driven Closed Loop — PostgreSQL `LISTEN`/`NOTIFY`

Instead of polling or a cron-scheduled retrain job, `init.sql` installs two trigger functions:

```sql
-- Fires on ANY change to the train table
CREATE TRIGGER train_alter_trig
AFTER INSERT OR UPDATE OR DELETE ON train
FOR EACH STATEMENT EXECUTE FUNCTION notify_train_change();   -- pg_notify('train_changed', ...)

-- Fires on every new row inserted into test
CREATE TRIGGER test_insert_trig
AFTER INSERT ON test
FOR EACH ROW EXECUTE FUNCTION notify_test_insert();           -- pg_notify('test_inserted', NEW.id)
```

FastAPI's `lifespan` hook opens a persistent `asyncpg` connection and registers listeners for both channels:

```mermaid
sequenceDiagram
    participant U as Data Producer
    participant PG as PostgreSQL
    participant API as FastAPI listener
    participant PRF as Prefect flow (subprocess)
    participant MLF as MLflow Registry

    U->>PG: INSERT / UPDATE train rows
    PG-->>API: NOTIFY train_changed
    API->>PRF: spawn training_pipeline.py
    PRF->>PRF: dvc repro ingest → featurize → train
    PRF->>MLF: log_model + register (Rossmann_XGBoost_Model)
    PRF-->>API: subprocess exit
    API->>MLF: pyfunc.load_model(latest)  (hot-swap, no restart)
    API->>PG: batch predict outstanding test rows
    U->>PG: INSERT new test rows
    PG-->>API: NOTIFY test_inserted
    API->>PG: batch predict immediately
```

The result: dropping new labeled data into Postgres autonomously triggers retraining, registry promotion, in-process model hot-swap, and rescoring — a genuine closed loop, not a manually re-triggered demo pipeline. A `POST /reload-model` endpoint is also exposed as a manual escape hatch.

### 8. Data Drift Monitoring — Evidently

`monitoring/drift.py` generates an HTML data-drift report using Evidently's `DataDriftPreset`, comparing a reference (training-time) dataset against current/live data — the standard first line of defense against silent model degradation once a model is in production.

---

## Deployment Architectures

The project ships **two parallel, fully-scripted deployment paths** targeting the same five services (`postgres`, `redis`, `mlflow`, `prefect`, `rossmann-api`):

| | **Docker Compose** | **Kubernetes (K3s) via Terraform** |
|---|---|---|
| Entry point | `dockerize.bat` → `docker-compose up -d --build` | `run_all.bat` → `terraform apply` |
| Networking | Single bridge network (`rossmann_network`) | K8s `LoadBalancer` Services per component |
| Persistence | Named Docker volumes (`postgres_data`, `mlflow_data`) | `PersistentVolumeClaim`s provisioned by K3s' local-path provisioner |
| Config injection | `environment:` block per service | `env {}` blocks + a `ConfigMap` for `init.sql` |
| Best for | Fast local iteration, debugging | Demonstrating production-representative container orchestration |

### Docker Compose (local development)

`docker-compose.yaml` defines five services on one bridge network. The `api` service builds from the root `Dockerfile`, mounts the live source tree for hot-reload (`WATCHFILES_FORCE_POLLING=true` — needed because filesystem-change events don't propagate reliably across the Docker Desktop/WSL2 volume boundary), and depends on the other four services being up first.

### Kubernetes via Terraform (production-representative)

The same five services are re-expressed as native Kubernetes objects in `terraform/main.tf` and applied against a local K3s cluster. See the deep dive below.

---

## Infrastructure-as-Code Deep Dive

`terraform/main.tf` uses the `hashicorp/kubernetes` provider (`~>2.24.0`) pointed at a kubeconfig extracted at deploy time (`terraform/k3s.yaml`), and provisions:

- **`kubernetes_config_map.postgres_init`** — embeds `init.sql` (schema + trigger functions) directly as cluster config, mounted into Postgres at `/docker-entrypoint-initdb.d`.
- **Three `PersistentVolumeClaim`s** (Postgres 2Gi, MLflow 2Gi, Prefect 1Gi), each with `wait_until_bound = false` — a deliberate workaround for a K3s local-path-provisioner deadlock where Terraform would otherwise block forever waiting for a PVC to bind before the pod that triggers the bind is even scheduled.
- **Four backing-service `Deployment` + `LoadBalancer Service` pairs** (Postgres, Redis, MLflow, Prefect), each with `image_pull_policy = "IfNotPresent"` so pre-pulled/pre-imported images are reused instead of re-fetched.
- **The `rossmann-api` `Deployment`**, which explicitly declares `depends_on` all four backing services so Terraform's apply order mirrors the application's real runtime dependency graph, and mounts the **same MLflow PVC** the MLflow server itself uses — letting the API read freshly registered model artifacts directly off disk without needing an S3-compatible artifact store.
- **A `LoadBalancer Service`** exposing the API on port `8000`.

```hcl
resource "kubernetes_persistent_volume_claim" "postgres_data" {
  metadata { name = "postgres-data-pvc" }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "2Gi" } }
  }
  wait_until_bound = false  # <-- Breaks the K3s storage deadlock
}
```

---

## One-Click Orchestration (`run_all.bat`)

The Kubernetes path is driven end-to-end by a single Windows batch script, structured as six explicit, fail-fast stages:

1. **Reset WSL & start K3s** — `wsl --shutdown` clears any ghost volume locks from a previous run, then a fresh K3s server is launched natively inside WSL (`k3s server --bind-address=127.0.0.1`), with a bounded polling loop (`kubectl get nodes`, 40 × 3s retries) waiting for the Kubernetes API to come online.
2. **Extract Terraform credentials** — copies the live `/etc/rancher/k3s/k3s.yaml` kubeconfig out of the WSL filesystem into `terraform/k3s.yaml` so the Terraform provider can authenticate.
3. **Pre-load base images into K3s' containerd cache** — `k3s ctr -n k8s.io images pull` for Postgres/Redis/MLflow/Prefect. This bypasses the Docker daemon entirely: **K3s uses containerd, not Docker, as its runtime**, so images have to be pulled directly into containerd's own image namespace.
4. **Build and import the custom API image** — `docker build` produces `rossmann-api:latest`, `docker save` exports it to a tarball, and `k3s ctr -n k8s.io images import` loads it into containerd's cache — the same Docker-vs-containerd bridge as step 3, but for a locally-built image instead of a registry pull.
5. **Verify/install Terraform** — delegates to `install_terraform.sh` (see below), then tears down any previous cluster state (`kubectl delete ... --ignore-not-found`) so re-runs are idempotent, before running `terraform init` and `terraform apply -auto-approve`.
6. **Roll out and expose** — `kubectl rollout restart` + `rollout status` on the API deployment, then opens four separate terminal windows, each running a self-healing `port-forward` loop piped into `kubectl logs -f`, for the API, MLflow, Prefect, and Postgres — giving live logs and local access (`localhost:8000`, `:5000`, `:4200`, `:5433`) simultaneously.

---

## Notable Engineering Problems Solved

These are the non-obvious issues actually hit and fixed while building this stack — the kind of detail that separates "it works on my machine" from a system someone has actually operated:

- **K3s runs on containerd, not Docker.** A `docker build` alone doesn't make an image visible to K3s. Fixed by explicitly exporting with `docker save` and importing into containerd's own `k8s.io` namespace via `k3s ctr images import`.
- **`cmd.exe` delayed expansion corrupts embedded bash.** Passing bash logic containing `!` characters inline through `wsl bash -c "..."` from a batch script with `setlocal enabledelayedexpansion` silently truncates everything after the `!`. Fixed by extracting the fragile logic into a standalone `install_terraform.sh` invoked from WSL, rather than inlining it in the `.bat` file.
- **A corrupted HashiCorp apt source blocked all package installs.** A stale/malformed `/etc/apt/sources.list.d/hashicorp.list` caused `apt-get update` to fail outright inside the WSL Ubuntu shell. Fixed by force-removing the file before re-adding the correct signed repository entry.
- **K3s' local-path PVC provisioner can deadlock under Terraform.** By default, Terraform waits for a `PersistentVolumeClaim` to reach `Bound` before proceeding — but K3s' provisioner only binds a volume once a pod that *uses* the claim is scheduled, which never happens if Terraform is still blocked on the PVC. Fixed with `wait_until_bound = false` on every PVC resource.
- **Feast silently materialized zero rows.** `feast materialize-incremental` uses a recent default lookback window, but the Rossmann dataset's timestamps (2013–2015) fell entirely outside it — so materialization "succeeded" with an empty Redis store and no error. Fixed by switching to explicit-range `feast materialize <start> <end>` spanning 2010–2030.
- **MLflow defaulted to a loopback-only bind address.** `mlflow server` binds to `127.0.0.1` unless told otherwise, making it unreachable from any other container or pod. Fixed with an explicit `--host 0.0.0.0`.
- **`localhost` doesn't resolve across container/pod boundaries.** `feature_store.yaml` and the API's default connection strings originally pointed at `localhost`; fixed by switching to Docker Compose/Kubernetes service DNS names (`postgres`, `redis`, `mlflow`, `prefect`).
- **Column-casing mismatch between Postgres and the trained schema.** Postgres columns are lowercase (`stateholiday`, `dayofweek`); the model was trained on PascalCase feature names (`StateHoliday`, `DayOfWeek`). Fixed with an explicit rename map applied consistently at every ingestion, training, and inference boundary — including inside the real-time Feast path.
- **Feature-order mismatches silently produce constant predictions.** The batch prediction path explicitly slices and re-orders columns into the exact training-time feature order before calling `.predict()`, and logs a warning if a batch produces a single repeated prediction value — a targeted defense against a bug class that fails silently rather than throwing.

---

## Prerequisites & Environment Setup

The Kubernetes/Terraform path is designed for **Windows + WSL2**. (The Docker Compose path only needs Docker Desktop and Python, and works cross-platform.) If you're setting up the full stack from a fresh Windows machine, follow these steps **in order**.

### Step 1 — Install WSL2 and Ubuntu

From an **elevated (Administrator) PowerShell**:

```powershell
wsl --install -d Ubuntu
```

This may require a restart. On first launch, the Ubuntu terminal will prompt you to create a UNIX username and password — remember the password, it's required for `sudo`. Then set Ubuntu as the default distribution:

```powershell
wsl --set-default Ubuntu
```

### Step 2 — Install Docker Desktop (with WSL2 integration)

On Windows, Docker is managed by **Docker Desktop**, which bridges the `docker` CLI directly into your Ubuntu environment — you do **not** install Docker natively inside Ubuntu.

1. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).
2. During install, check **"Use WSL 2 instead of Hyper-V."**
3. Open Docker Desktop → **Settings → Resources → WSL Integration**.
4. Enable the toggle for **Ubuntu**.
5. Click **Apply & Restart**.

### Step 3 — Install Python, K3s, and Terraform inside Ubuntu

Open the **Ubuntu terminal** (via the Windows Start menu) and run:

**Python 3 + build tools:**

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y python3 python3-pip python3-venv build-essential
```

**K3s (lightweight Kubernetes):**

```bash
curl -sfL https://get.k3s.io | sh -
```

**Terraform:**

```bash
sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
```

> The repository also ships `install_terraform.sh`, which performs an idempotent version of this same install (with the corrupted-apt-source fix baked in) and is run automatically by `run_all.bat`.

---

## Quickstart

### Path A — Docker Compose (fastest, recommended for local dev)

```bash
git clone https://github.com/benkeddad/mlops-demand-forecast.git
cd mlops-demand-forecast
docker-compose up -d --build
```

Or use the bundled helper, which tears down old containers/volumes first:

```bat
dockerize.bat
```

Once containers are healthy: API docs at `http://localhost:8000/docs`, MLflow at `http://localhost:5000`, Prefect at `http://localhost:4200`, Postgres at `localhost:5432`.

### Path B — Kubernetes via Terraform (K3s on WSL2)

After completing [Prerequisites](#prerequisites--environment-setup):

1. Ensure **Docker Desktop is running**.
2. Right-click `run_all.bat` → **Run as Administrator** (elevated privileges are required to manage WSL instances, the Docker daemon, and storage mounts).

The script runs all six stages described in [One-Click Orchestration](#one-click-orchestration-run_allbat) unattended and finishes by opening live log/port-forward windows for every service.

---

## API Reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Redirects to the interactive Swagger UI (`/docs`) |
| `GET` | `/health` | Liveness + model-loaded status check |
| `POST` | `/reload-model` | Forces an immediate reload of the latest registered MLflow model |
| `GET` | `/predict/realtime/{store_id}` | Real-time single-store prediction via the Feast/Redis online store (<10ms feature retrieval) |

```bash
# Health check
curl http://localhost:8000/health

# Real-time prediction for store 1
curl http://localhost:8000/predict/realtime/1

# Force a model reload after manual retraining
curl -X POST http://localhost:8000/reload-model
```

Batch prediction isn't exposed as a manually-called endpoint by design — it's triggered automatically whenever new rows land in the `test` table, or immediately after a retraining cycle completes (see [Event-Driven Closed Loop](#7-event-driven-closed-loop--postgresql-listennotify)).

---

## Configuration Reference

Environment variables consumed by the API and pipeline scripts (defaults shown are the Docker Compose/Kubernetes service-DNS values):

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | `postgresql://user:Password@postgres:5432/rossmann` | Postgres connection string (both `asyncpg` and SQLAlchemy paths) |
| `MODEL_URI` | `models:/Rossmann_XGBoost_Model/latest` | MLflow Model Registry URI resolved at load/reload time |
| `MLFLOW_TRACKING_URI` | `http://mlflow:5000` | MLflow tracking + registry endpoint |
| `PREFECT_API_URL` | `http://prefect:4200/api` | Prefect server API endpoint used by the orchestration flow |
| `WATCHFILES_FORCE_POLLING` | `true` | Forces filesystem-change polling — needed for reliable hot-reload across the Docker Desktop/WSL2 volume boundary |

---

## CI/CD

`.github/workflows/ci.yml` runs on every push/PR to `main`:

1. Checks out the repo and sets up **Python 3.9**.
2. Installs `flake8`, `pytest`, and `requirements.txt`.
3. Lints with `flake8` restricted to fatal error classes (`E9,F63,F7,F82` — syntax errors and undefined names), so the build fails fast on actually broken code rather than style nitpicks.
4. Runs `pytest` (currently a placeholder — see [Roadmap](#roadmap)).

---

## Troubleshooting

- **"K3s did not come up after 2 minutes"** — Increase the RAM allocated to WSL2 by creating a `.wslconfig` file in your Windows user profile folder.
- **"Docker build failed"** — Confirm `Dockerfile` exists at the repo root and is syntactically valid.
- **"Terraform command not found" inside the script** — Re-run Step 3 of the [Prerequisites](#prerequisites--environment-setup), then restart the Ubuntu terminal.
- **Permission denied errors** — `run_all.bat` must be run as Administrator; it manages WSL instances, the Docker daemon, and storage mounts.
- **Feast returns 404 / empty features for a real-time prediction** — the online store hasn't been materialized yet; re-run `feast materialize-incremental` (or the wide-range `feast materialize` used in this repo) from `feature_repo/`.

---

## Security & Production-Readiness Notes

Some deliberate shortcuts were made to keep this a clear, runnable local/portfolio demo — flagged here explicitly rather than left implicit:

- Postgres credentials (`user` / `Password`) are hardcoded in plaintext in `docker-compose.yaml` and `terraform/main.tf` instead of being injected via Docker secrets or a Kubernetes `Secret`.
- All Kubernetes `Service` objects use `type: LoadBalancer`, which on a single-node K3s cluster simply exposes a NodePort-equivalent — there's no ingress controller, TLS termination, or authentication in front of any service.
- MLflow's `--default-artifact-root` and `--backend-store-uri` point at local PVC-backed SQLite/files rather than an object store (S3/GCS) + managed database, which won't horizontally scale past a single node.
- The Prefect flow is triggered as an ad-hoc `subprocess` from the API process rather than as a scheduled/deployed Prefect flow run — fine for a single-node demo, but not how you'd want to trigger training in a multi-replica deployment.

---

## Roadmap

- [ ] Real `pytest` coverage for `src/`, `app/`, and `pipelines/` (CI currently only lints for fatal syntax errors)
- [ ] Move DVC remote storage from local disk to S3/GCS for true team-shared reproducibility
- [ ] Replace plaintext Postgres credentials with Kubernetes `Secret`s
- [ ] Convert the ad-hoc Prefect `subprocess` trigger into a proper scheduled/deployed Prefect flow run
- [ ] Add an Ingress + TLS in front of the Kubernetes services instead of raw `LoadBalancer` exposure
- [ ] Wire `monitoring/drift.py` into a scheduled job against live inference logs, rather than a manually-invoked script

---

## About

Built by **Youcef Benkeddad** ([@benkeddad](https://github.com/benkeddad)) as a hands-on demonstration of end-to-end MLOps engineering — data versioning, feature stores, orchestration, experiment tracking, container orchestration, and infrastructure as code, wired into one working, closed-loop system rather than shown as isolated pieces.
