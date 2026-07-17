# MLOps Demand Forecasting Platform — Rossmann Store Sales

![Python](https://img.shields.io/badge/python-3.9-blue?logo=python&logoColor=white)
![XGBoost](https://img.shields.io/badge/model-XGBoost-006400)
![MLflow](https://img.shields.io/badge/tracking%20%2B%20registry-MLflow-0194E2)
![Prefect](https://img.shields.io/badge/orchestration-Prefect%202-024DFD)
![DVC](https://img.shields.io/badge/data%20versioning-DVC-945DD6)
![Feast](https://img.shields.io/badge/feature%20store-Feast-FF5A5F)
![Evidently](https://img.shields.io/badge/drift%20monitoring-Evidently-FF4B4B)
![FastAPI](https://img.shields.io/badge/serving-FastAPI-009688?logo=fastapi&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/database-PostgreSQL%2015-4169E1?logo=postgresql&logoColor=white)
![Redis](https://img.shields.io/badge/online%20store-Redis%207-DC382D?logo=redis&logoColor=white)
![Docker](https://img.shields.io/badge/containers-Docker-2496ED?logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/orchestration-Kubernetes%20(K3s)-326CE5?logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/CI-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)

A closed-loop, **event-driven** demand forecasting system for Rossmann retail sales (1,017,209 historical rows across 1,115 stores), built to demonstrate a complete, production-shaped MLOps stack rather than a notebook-to-API demo. Inserting a row into PostgreSQL is enough to trigger feature materialization, retraining, model registration, and a live in-memory model hot-swap — no cron jobs, no polling loops, no manual "now run the pipeline" step.

The system ships with **two independent, fully automated deployment paths** — a Docker Compose stack for local iteration, and a Terraform-provisioned Kubernetes (K3s) deployment for a production-representative environment — both running the identical five-service architecture from the same source.

---

## Table of Contents

1. [Architecture at a Glance](#architecture-at-a-glance)
2. [Full MLOps Tech Stack](#full-mlops-tech-stack)
3. [Repository Structure](#repository-structure)
4. [Core MLOps Capabilities](#core-mlops-capabilities)
5. [Deployment Architectures](#deployment-architectures)
6. [Infrastructure-as-Code Deep Dive](#infrastructure-as-code-deep-dive)
7. [Deployment Automation Scripts](#deployment-automation-scripts)
8. [Notable Engineering Problems Solved](#notable-engineering-problems-solved)
9. [Prerequisites & Environment Setup](#prerequisites--environment-setup)
10. [Quickstart](#quickstart)
11. [API Reference](#api-reference)
12. [Configuration Reference](#configuration-reference)
13. [CI/CD](#cicd)
14. [Security & Production-Readiness Notes](#security--production-readiness-notes)
15. [Roadmap](#roadmap)
16. [About](#about)

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

    subgraph Pipe["DVC Pipeline (dvc.yaml)"]
        ING[ingest<br/>src/data.py]
        FEA[featurize<br/>src/features.py]
        TRN[train<br/>src/train.py]
        ING --> FEA --> TRN
    end

    FS{Feast Feature Store}
    API[FastAPI + Uvicorn<br/>rossmann-api]

    PG -- "LISTEN/NOTIFY<br/>train_changed" --> API
    PG -- "LISTEN/NOTIFY<br/>test_inserted" --> API
    API -- "subprocess.Popen<br/>training_pipeline.py" --> PRF
    PRF --> ING
    ING -- "reads train table" --> PG
    FEA -- "feast apply / materialize" --> FS
    FS -- "offline reads (point-in-time)" --> PG
    FS -- "online writes" --> RD
    TRN -- "log_model + register" --> MLF
    API -- "pyfunc.load_model(latest)<br/>on reload" --> MLF
    API -- "batch predict, writes<br/>predicted_sales back" --> PG
    API -- "GET /predict/realtime" --> FS
    FS -- "online reads (<10ms)" --> RD
```

**The core idea:** PostgreSQL isn't just a data store here — it doubles as a lightweight event bus via `pg_notify` triggers defined in `db/init.sql`. FastAPI holds a permanent `asyncpg` listener open on two channels (`train_changed`, `test_inserted`), so the whole retrain → register → reload → rescore cycle happens autonomously and is fully observable through the MLflow and Prefect UIs — a real implementation of the "trigger-based retraining" pattern that's usually only discussed in MLOps theory.

---

## Full MLOps Tech Stack

Every library below is a deliberate choice pulled directly from `requirements.txt`, the three Dockerfiles, and the Terraform provider block — nothing here is decorative.

| Discipline | Tool | Pin (as declared in the repo) | Role in this project |
|---|---|---|---|
| **Data & pipeline versioning** | DVC | `>=3.50.0` | Owns caching/reproducibility for the `ingest → featurize → train` stages (`dvc.yaml`); each stage is content-hashed against its declared `deps`/`outs` and only reruns when they actually change |
| — Windows-compat pins for DVC | `dvc-objects`, `pathspec` | `>=3.0.0`, `>=0.12.0,<1.0.0` | Explicit version floors added after hitting real cross-platform breakage running DVC's cache layer under Windows/WSL2 |
| **Workflow orchestration** | Prefect 2 (self-hosted server) | `>=2.14.0,<3.0.0` | Wraps the three DVC stages as a tracked, retryable flow (`Rossmann-Enterprise-Pipeline`) with a queryable run-history UI |
| **Feature store (offline + online)** | Feast | `feast[postgres,redis]` | Guarantees training/serving parity: PostgreSQL as the point-in-time-correct offline source, Redis as the sub-10ms online cache, and a dedicated `feast` Postgres database as the **SQL registry** (not a flat file) |
| **Experiment tracking & model registry** | MLflow | `>=2.10.0` | Logs params/metrics/dataset lineage per run and versions the trained model under a named Model Registry entry that the API resolves by URI at load/reload time |
| **Model** | XGBoost (`XGBRegressor`) | `>=1.7.0` | Gradient-boosted regression tree ensemble forecasting daily per-store sales (`objective="reg:squarederror"`) |
| **Model serving** | FastAPI + Uvicorn | `>=0.100.0` / `>=0.22.0` | Async, non-blocking web layer exposing real-time inference, forced reloads, and health checks; runs an `asyncio` background task alongside the request loop |
| **Data validation / typing** | Pydantic | `>=2.0.0` | Backs FastAPI's request/response models |
| **Data drift monitoring** | Evidently | `>=0.4.0,<0.7.0` | `DataDriftPreset` run over live Postgres data (`monitoring/drift.py`), logged to MLflow as its own experiment, with a `--fail-on-drift` exit code for automation |
| **Relational storage / event bus** | PostgreSQL 15 (`alpine`) | image `postgres:15-alpine` | System of record for `train`/`test`; source of `pg_notify` events; shared backend for its own data **plus** MLflow's, Prefect's, and Feast's metadata (one database each, one Postgres instance) |
| **Online feature cache** | Redis 7 (`alpine`) | image `redis:7-alpine` | Backs Feast's online store for millisecond-latency feature lookups at inference time |
| **Containerization** | Docker + Docker Compose | — | Three purpose-built images (`docker/`) and a 5-service local dev stack (`deploy/docker-compose.yaml`) |
| **Container orchestration** | Kubernetes (K3s) | — | Lightweight, single-binary Kubernetes distribution used as the production-representative runtime, run natively inside WSL2 |
| **Infrastructure as Code** | Terraform | `hashicorp/kubernetes ~> 2.24.0`, core `>= 1.0.0` | Declaratively provisions every `Deployment`, `Service`, `PersistentVolumeClaim`, and `ConfigMap` the stack needs (`deploy/terraform/main.tf`) |
| **CI** | GitHub Actions | — | Lints (`flake8`) and test-gates every push/PR to `main` |
| **DB access — async** | `asyncpg` | `==0.29.0` | Powers FastAPI's `LISTEN/NOTIFY` event loop and low-latency batch writes; also the driver Prefect's server uses internally against its own database |
| **DB access — sync, autocommit-required** | `psycopg2-binary` | `==2.9.0` | Used where `CREATE DATABASE` has to run outside a transaction block (`app/db_bootstrap.py`); also the driver MLflow's server uses internally |
| **DB access — sync, pooled** | `psycopg[binary,pool]` | unpinned | Feast's PostgreSQL offline store driver |
| **DB access — ORM / DataFrame I/O** | SQLAlchemy | `==2.0.0` | `create_engine` + `pd.read_sql` / `df.to_sql` used everywhere a pipeline script needs to move a whole table in or out of Postgres (`src/data.py`, `src/seed_db.py`, `src/predict_initial.py`, `monitoring/drift.py`) |
| **Numerical / data stack** | pandas, NumPy, scikit-learn, PyArrow, openpyxl | `>=2.0.0` / `>=1.24.0` / `>=1.2.0` / `>=14.0.0` / `>=3.1.0` | DataFrame transforms, `train_test_split`, fast Parquet I/O between DVC stages, Excel compatibility |
| **Dev ergonomics** | `watchdog` | `>=3.0.0` | Backs Uvicorn's `--reload`; `WATCHFILES_FORCE_POLLING=true` is set because file-change events don't cross the Docker Desktop ↔ WSL2 volume boundary reliably otherwise |

**Why three different PostgreSQL client libraries instead of one?** Each has a genuinely different job: `asyncpg` is the only one of the three that supports async `LISTEN/NOTIFY`, which the event-driven API loop depends on; `psycopg2` is used specifically where a connection must run in `AUTOCOMMIT` mode to issue `CREATE DATABASE` (which PostgreSQL refuses to allow inside a transaction); and SQLAlchemy's `create_engine` is what `pandas.read_sql` / `.to_sql` expect under the hood for whole-table I/O. Using the "one ORM to rule them all" approach here would have meant fighting the tool instead of using it.

---

## Repository Structure

```
mlops-demand-forecast/
├── app/
│   ├── main.py                # FastAPI app: lifespan hook, LISTEN/NOTIFY loop, inference routes
│   └── db_bootstrap.py        # Idempotent "ensure these 4 databases exist" check, run on every boot
├── src/
│   ├── data.py                 # DVC "ingest" stage — pulls `train` table from Postgres → parquet
│   ├── features.py             # DVC "featurize" stage — builds features, applies + materializes Feast
│   ├── model.py                 # XGBRegressor factory
│   ├── train.py                 # DVC "train" stage — trains, evaluates, logs + registers to MLflow
│   ├── evaluate.py              # RMSPE metric (zero-sales days masked out)
│   ├── predict_initial.py       # One-shot batch scoring pass run at container bootstrap
│   └── seed_db.py               # Idempotent CSV → Postgres loader for train/test tables
├── pipelines/
│   └── training_pipeline.py     # Prefect flow wrapping the three DVC stages as tasks
├── feature_repo/
│   ├── feature_store.yaml       # Feast project config — Postgres offline / Redis online / SQL registry
│   ├── features.py              # Entity + FeatureView + PostgreSQLSource definitions
│   └── materialize.py           # Standalone wide-window materialization utility
├── monitoring/
│   ├── drift.py                  # Postgres-driven drift monitor, logs to MLflow
│   └── reports/                  # Timestamped HTML drift reports (generated at runtime)
├── docker/
│   ├── api.Dockerfile             # FastAPI + full pipeline image (python:3.9-slim base)
│   ├── mlflow.Dockerfile          # Upstream MLflow image + psycopg2-binary
│   ├── prefect.Dockerfile         # Upstream Prefect 2.14 image + asyncpg
│   └── entrypoint.sh               # Container bootstrap sequence (see below)
├── db/
│   ├── init.sql                    # train/test schema + LISTEN/NOTIFY trigger definitions
│   └── create-databases.sql        # First-boot-only CREATE DATABASE for mlflow / prefect / feast
├── deploy/
│   ├── docker-compose.yaml         # Local 5-service stack definition
│   └── terraform/
│       ├── main.tf                  # Full K8s resource graph
│       └── k3s.yaml                 # Generated kubeconfig (copied out of WSL2 at deploy time)
├── scripts/
│   ├── deploy_k3s_clean.bat          # Full destructive rebuild: WSL2 → K3s → images → Terraform
│   ├── deploy_k3s_reconcile.bat      # Non-destructive: only touches unhealthy/missing resources
│   ├── deploy_compose_clean.bat      # Full rebuild of the Docker Compose stack, no cache
│   ├── scriptsdeploy_compose_reconcile.bat  # `docker-compose up -d` reconciliation, no rebuild
│   └── install_terraform.sh          # Idempotent Terraform installer for the WSL2 Ubuntu shell
├── .github/workflows/ci.yml        # Lint + test GitHub Actions workflow
├── dvc.yaml                        # DVC stage graph (ingest → featurize → train)
└── requirements.txt                 # Full Python dependency set
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

Each stage only re-executes when its declared dependencies actually change — reproducible, cache-aware reruns instead of "just run everything every time." DVC is deliberately kept in charge of *what* needs to rerun, while Prefect is kept in charge of *when* it runs and *how it's observed*.

### 2. Workflow Orchestration — Prefect

`pipelines/training_pipeline.py` wraps the three DVC stages as a Prefect flow:

```python
@flow(name="Rossmann-Enterprise-Pipeline")
def ml_training_pipeline():
    dvc_ingest()     # @task, retries=1, "dvc repro --force ingest"
    dvc_featurize()  # @task, "dvc repro featurize"
    dvc_train()      # @task, "dvc repro train"
```

This layers Prefect *on top of* DVC rather than replacing it: DVC gives content-hash caching and stage-level reproducibility; Prefect gives retries, run history, and a queryable UI (`http://localhost:4200`) for every execution — a common production pattern for teams that want orchestration observability without giving up file-level pipeline caching. The Prefect server persists its own flow-run history in a dedicated `prefect` Postgres database rather than the default local SQLite file.

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

- **Offline store:** PostgreSQL — point-in-time-correct historical feature retrieval for training.
- **Online store:** Redis — millisecond-latency lookups at inference time.
- **Registry:** a dedicated `feast` Postgres database (`registry_type: sql`), not a local `.db` file, so feature/entity definitions resolve consistently no matter which container or pod asks.
- **TTL:** 3650 days — deliberately wide, because the Rossmann dataset's historical range (2013–2015) would otherwise fall outside Feast's default lookback window (see [Notable Engineering Problems Solved](#notable-engineering-problems-solved)).

This is the textbook feature-store guarantee: the *same* feature-engineering logic (`src/features.py::build_features`) serves both the training pipeline and the real-time API, eliminating training/serving skew — and `monitoring/drift.py` deliberately reuses that same function again for drift comparisons, so drift is measured against the model's real input schema rather than a re-implementation that could quietly diverge.

### 4. Experiment Tracking & Model Registry — MLflow

`src/train.py` logs a fully lineage-tracked run for every training pass:

```python
mlflow.set_experiment("Rossmann_Sales_Forecasting")
with mlflow.start_run():
    dataset = mlflow.data.from_pandas(processed_df, source=processed_data_path)
    mlflow.log_input(dataset, context="training")          # exact data lineage, not just a metric

    model = get_model(n_estimators=150, max_depth=8)
    model.fit(X_train, y_train)

    mlflow.log_param("model_type", "XGBRegressor")
    mlflow.log_metric("val_rmspe", rmspe_score)

    mlflow.xgboost.log_model(
        xgb_model=model,
        artifact_path="xgboost_model",
        registered_model_name="Rossmann_XGBoost_Model",   # → Model Registry, not just the artifact store
    )
```

The API resolves the model with `MODEL_URI = "models:/Rossmann_XGBoost_Model/latest"` — a live Model Registry pointer, not a hardcoded run ID — so a fresh registration is picked up automatically on the next reload without redeploying the API.

### 5. Model — XGBoost

`src/model.py` is a small, explicit factory rather than inline hyperparameters scattered through the training script:

```python
xgb.XGBRegressor(
    objective="reg:squarederror",
    learning_rate=0.1, max_depth=6, n_estimators=100,   # defaults; train.py overrides to 150/8
    random_state=42,
)
```

Evaluated with **RMSPE** (Root Mean Square Percentage Error, `src/evaluate.py`) — the standard metric for the Rossmann competition — with zero-sales days explicitly masked out of the denominator to avoid division-by-zero distortion.

### 6. Model Serving — FastAPI with Two Distinct Inference Paths

`app/main.py` exposes **real-time single-entity inference** and an **event-triggered batch path**, deliberately kept separate because they hit different storage layers:

- **Real-time (`GET /predict/realtime/{store_id}`):** looks up the latest feature snapshot for one store from **Redis via Feast** (`feast_store.get_online_features`, run in a thread since Feast's SDK is synchronous), then runs inference immediately. Response includes the retrieved feature vector for transparency.
- **Batch (`perform_batch_prediction`, triggered by the `test_inserted` DB event or right after retraining finishes):** pulls every row from `test` where `predicted_sales IS NULL` via `asyncpg`, reconstructs features locally with the exact same `build_features` function used in training, and bulk-writes predictions back with `executemany`.

Both paths independently enforce the same defensive column ordering before calling `.predict()`:

```python
feature_cols = ["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]
features_only = processed_df[feature_cols].copy()
```

and the batch path goes one step further — it checks whether an entire batch produced a single repeated prediction value and logs a warning if so, a targeted defense against a bug class (feature-order drift) that otherwise fails silently instead of throwing.

### 7. Event-Driven Closed Loop — PostgreSQL `LISTEN`/`NOTIFY`

This is the architectural centerpiece. `db/init.sql` defines two triggers:

```sql
CREATE TRIGGER train_alter_trig AFTER INSERT OR UPDATE OR DELETE ON train
FOR EACH STATEMENT EXECUTE FUNCTION notify_train_change();   -- pg_notify('train_changed', 'update')

CREATE TRIGGER test_insert_trig AFTER INSERT ON test
FOR EACH ROW EXECUTE FUNCTION notify_test_insert();           -- pg_notify('test_inserted', NEW.id::text)
```

FastAPI's lifespan hook opens a permanent `asyncpg` listener on both channels (`app/main.py::run_postgres_event_loop`, auto-reconnecting on connection loss):

```python
await conn.add_listener('train_changed', handle_train_db_trigger)
await conn.add_listener('test_inserted', handle_predict_db_trigger)
```

- A write to `train` → `handle_train_db_trigger` spawns `pipelines/training_pipeline.py` as a subprocess → once it exits, `wait_and_reload` reloads the MLflow model in-process and fires a background batch-prediction pass.
- A write to `test` → `handle_predict_db_trigger` calls the exact same `perform_batch_prediction` function directly.

No polling, no scheduler, no manual "please retrain now" step — the database itself is the trigger.

### 8. Data Drift Monitoring — Evidently

`monitoring/drift.py` is a full CLI tool, not a notebook cell:

```
python monitoring/drift.py --drift-share-threshold 0.3 --fail-on-drift
```

- Loads the `train` (reference) and `test` (current) populations from Postgres, running both through the **same** `build_features` transform used in training.
- Runs Evidently's `DataDriftPreset` over the shared model-input columns.
- Saves a timestamped HTML report (`monitoring/reports/`, never overwritten).
- Logs `drift_share`, `n_drifted_columns`, and `dataset_drift` as an MLflow run in its own `data-drift-monitoring` experiment — so drift history is queryable in the same tracking server as training runs, over time.
- Exits non-zero when drift crosses `--drift-share-threshold`, making it a valid automated retraining trigger for a cron job, a CI step, or a Prefect deployment — nothing currently schedules it (see [Roadmap](#roadmap)), but the automation contract is already built.

`requirements.txt` deliberately pins `evidently>=0.4.0,<0.7.0`, with an inline comment explaining why: `drift.py` parses `report.as_dict()["metrics"][0]["result"]`, and Evidently's 0.7 rewrite changed that schema — an easy silent-breakage trap that's headed off with an explicit upper bound instead of discovering it in production.

### 9. Idempotent Multi-Database Bootstrap

Four logical databases live on one PostgreSQL instance: `rossmann` (app data), `mlflow`, `prefect`, `feast`. `db/create-databases.sql` creates three of them via Postgres's `docker-entrypoint-initdb.d` convention — but that mechanism **only ever runs once**, against a completely empty data directory. `app/db_bootstrap.py` exists specifically to cover the case that convention doesn't: it connects to the system `postgres` database with `psycopg2` in `AUTOCOMMIT` mode, checks `pg_catalog.pg_database` for all four expected databases, and creates any that are missing — and it runs on **every** API container start, not just first boot, so a redeploy against an existing volume with newly-added requirements never crashes with "database does not exist."

---

## Deployment Architectures

### Path A — Docker Compose (local development)

`deploy/docker-compose.yaml` defines five services on a shared bridge network (`rossmann_network`): `postgres` (with a real `pg_isready` healthcheck), `redis`, `mlflow` and `prefect` (both **built locally** from custom Dockerfiles rather than pulled from upstream — see below), and `api`. The `mlflow` and `prefect` services use `depends_on: condition: service_healthy` against Postgres and `restart: on-failure:5`, so they don't crash-loop against a database that hasn't finished starting yet. The `api` service bind-mounts the entire repo root (`..:/app`) for live hot-reload during development, with `WATCHFILES_FORCE_POLLING=true` set because filesystem-change events don't reliably cross the Docker Desktop ↔ WSL2 volume boundary otherwise.

### Path B — Kubernetes via Terraform (K3s on WSL2)

The same five-service topology, re-expressed as native Kubernetes resources and provisioned declaratively instead of imperatively. K3s runs natively inside WSL2 (not inside Docker Desktop's own VM), and Terraform talks to it directly via a kubeconfig extracted from `/etc/rancher/k3s/k3s.yaml`. This path is described in full in the next section.

---

## Infrastructure-as-Code Deep Dive

`deploy/terraform/main.tf` (Terraform `>= 1.0.0`, `hashicorp/kubernetes ~> 2.24.0`) declares:

- **Three `PersistentVolumeClaim`s** (Postgres 2Gi, MLflow 2Gi, Prefect 1Gi), each with `wait_until_bound = false` — a deliberate fix for a K3s-specific deadlock (see below).
- **Four backing-service `Deployment` + `LoadBalancer Service` pairs** (Postgres, Redis, MLflow, Prefect), each with `image_pull_policy = "IfNotPresent"` so pre-imported images are reused instead of re-fetched. MLflow and Prefect run **custom-built images** (`rossmann-mlflow:latest`, `rossmann-prefect:latest`), not the stock upstream ones.
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

## Deployment Automation Scripts

The Kubernetes path ships **two** deployment scripts with different risk profiles, plus a matched pair for Docker Compose — not one "just run this" script:

| Script | Behavior |
|---|---|
| `scripts\deploy_k3s_clean.bat` | **Destructive, six-stage full rebuild.** `wsl --shutdown` to clear ghost volume locks → starts a fresh K3s server natively in WSL2, polling `kubectl get nodes` (40 × 3s retries) → extracts the kubeconfig for Terraform → pre-pulls stock Postgres/Redis images directly into containerd's `k8s.io` namespace → builds **and imports** all three custom images (`docker build` → `docker save` → `k3s ctr images import`, each individually error-checked) → verifies/installs Terraform → deletes all previous K8s resources **including PVCs** → `terraform init && terraform apply -auto-approve` → rolls out the API and opens four live log/port-forward windows. Use this for a first deploy or a truly clean slate. |
| `scripts\deploy_k3s_reconcile.bat` | **Non-destructive recovery/redeploy.** Checks whether K3s is already running via `systemctl is-active`; starts it only if needed. Individually checks every ConfigMap, PVC, Service, and Deployment the stack needs — runs `terraform apply` only if something is actually missing. For each of the five Deployments, checks `kubectl rollout status` with a short timeout and only issues a `rollout restart` if it's unhealthy. **Never deletes PVCs, state, or existing deployments.** Use this for "I already deployed once and just want it running again." |
| `scripts\deploy_compose_clean.bat` | Full Compose teardown (`down --volumes --rmi all --remove-orphans`), no-cache rebuild of every image, then `up -d --force-recreate`. |
| `scripts\scriptsdeploy_compose_reconcile.bat` | Validates the Compose file (`config --quiet`) then `up -d` — starts anything missing/stopped, leaves healthy containers and volumes untouched. |
| `scripts\install_terraform.sh` | Idempotent Terraform installer for the WSL2 Ubuntu shell — checks for an existing binary, installs `unzip` if needed (with a fix for a corrupted apt source baked in), then downloads and installs the Terraform `1.9.0` Linux binary directly rather than going through HashiCorp's apt repository. Invoked automatically by both K3s deploy scripts. |

Every K3s-path script runs from the Windows side and drives WSL2 via `wsl -u root ...` — nothing has to be manually typed inside the Ubuntu terminal once these scripts exist.

---

## Notable Engineering Problems Solved

The kind of detail that separates "it works on my machine" from a system someone has actually operated:

- **K3s runs on containerd, not Docker.** A `docker build` alone doesn't make an image visible to K3s. Fixed by explicitly exporting with `docker save` and importing into containerd's own `k8s.io` namespace via `k3s ctr images import`.
- **`cmd.exe` delayed expansion corrupts embedded bash.** Passing bash logic containing `!` characters inline through `wsl bash -c "..."` from a batch script with `setlocal enabledelayedexpansion` silently truncates everything after the `!`. Fixed by extracting the fragile logic into a standalone `install_terraform.sh` invoked from WSL2, rather than inlining it in the `.bat` file.
- **A corrupted HashiCorp apt source blocked all package installs.** A stale/malformed `/etc/apt/sources.list.d/hashicorp.list` caused `apt-get update` to fail outright inside the WSL2 Ubuntu shell — even for installing `unzip`, which has nothing to do with HashiCorp. Fixed by force-removing the file before continuing.
- **K3s' local-path PVC provisioner can deadlock under Terraform.** By default, Terraform waits for a `PersistentVolumeClaim` to reach `Bound` before proceeding — but K3s' provisioner only binds a volume once a pod that *uses* the claim is scheduled, which never happens if Terraform is still blocked on the PVC. Fixed with `wait_until_bound = false` on every PVC resource.
- **Feast silently materialized zero rows.** `feast materialize-incremental` uses a recent default lookback window, but the Rossmann dataset's timestamps (2013–2015) fell entirely outside it — so materialization "succeeded" with an empty Redis store and no error. Fixed by switching to explicit-range `feast materialize 2010-01-01T00:00:00 2030-12-31T23:59:59`.
- **MLflow defaults to a loopback-only bind address.** `mlflow server` binds to `127.0.0.1` unless told otherwise, making it unreachable from any other container or pod. Fixed with an explicit `--host 0.0.0.0`.
- **`localhost` doesn't resolve across container/pod boundaries.** `feature_store.yaml` and the API's default connection strings originally pointed at `localhost`; fixed by switching to Docker Compose/Kubernetes service DNS names (`postgres`, `redis`, `mlflow`, `prefect`).
- **Column-casing mismatch between Postgres and the trained schema.** Postgres columns are lowercase (`stateholiday`, `dayofweek`); the model was trained on PascalCase feature names (`StateHoliday`, `DayOfWeek`). Fixed with an explicit rename map applied consistently at every ingestion, training, and inference boundary — including the real-time Feast path.
- **Feature-order mismatches silently produce constant predictions.** The batch prediction path explicitly slices and re-orders columns into the exact training-time feature order before calling `.predict()`, and logs a warning if a batch produces a single repeated prediction value — a targeted defense against a bug class that fails silently rather than throwing.
- **The official MLflow and Prefect images don't ship a PostgreSQL driver.** Pointing `mlflow server --backend-store-uri postgresql://...` or Prefect's `PREFECT_API_DATABASE_CONNECTION_URL` at Postgres crashes immediately with a missing-module error (`psycopg2` / `asyncpg` respectively) — neither upstream image bundles them. Fixed with two tiny custom images (`docker/mlflow.Dockerfile`, `docker/prefect.Dockerfile`) that just add the one missing driver on top of the official base.
- **`docker-entrypoint-initdb.d` scripts only run once, ever.** Postgres only executes `db/create-databases.sql` on a **completely empty** data directory — so on any redeploy against an existing volume, newly-added `CREATE DATABASE` statements silently never run, and dependent services fail with "database does not exist." Fixed with `app/db_bootstrap.py`, an idempotent check-then-create step that runs on **every** API container start.
- **A silent Evidently schema break, headed off before it happened.** `monitoring/drift.py` parses Evidently's report output at a specific dict path (`report.as_dict()["metrics"][0]["result"]`). Evidently's 0.7 release restructured that schema. Rather than discover this the hard way, `requirements.txt` pins `evidently>=0.4.0,<0.7.0` with an inline comment explaining exactly why the ceiling is there.

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

**Terraform** — two valid routes:

*Option A: the standard cross-distro HashiCorp apt repository, done by hand:*

```bash
sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
```

*Option B (what this repo actually automates): let `scripts\install_terraform.sh` handle it.* It does **not** use the apt-repository route above — it downloads the Terraform `1.9.0` Linux binary directly from `releases.hashicorp.com`, unzips it into `/usr/local/bin/`, and is idempotent (skips the whole thing if `terraform` is already on `PATH`). It also carries the corrupted-apt-source fix baked in, since it needs `unzip` installed first. This script runs automatically as part of both `scripts\deploy_k3s_clean.bat` and `scripts\deploy_k3s_reconcile.bat`, so in practice you can skip Option A entirely and just run one of those two scripts.

> **Reference Python version:** the API image (`docker/api.Dockerfile`) and CI both pin **Python 3.9**. Match that locally if you're running anything outside a container to avoid subtle dependency-resolution differences.

---

## Quickstart

### Path A — Docker Compose (fastest, recommended for local dev)

```bash
git clone https://github.com/benkeddad/mlops-demand-forecast.git
cd mlops-demand-forecast
docker compose -f deploy/docker-compose.yaml up -d --build
```

Or use the bundled helpers:

```bat
:: First run / full rebuild (destroys existing containers, volumes, and images first)
scripts\deploy_compose_clean.bat

:: Subsequent runs — starts what's missing, leaves healthy containers/volumes alone
scripts\scriptsdeploy_compose_reconcile.bat
```

Once containers are healthy: API docs at `http://localhost:8000/docs`, MLflow at `http://localhost:5000`, Prefect at `http://localhost:4200`, Postgres at `localhost:5432`.

### Path B — Kubernetes via Terraform (K3s on WSL2)

After completing [Prerequisites](#prerequisites--environment-setup):

1. Ensure **Docker Desktop is running**.
2. Right-click the appropriate script → **Run as Administrator** (elevated privileges are required to manage WSL2 instances, the Docker daemon, and storage mounts):
   - **First deploy, or want a guaranteed clean slate:** `scripts\deploy_k3s_clean.bat`
   - **Already deployed once, just restarting/recovering:** `scripts\deploy_k3s_reconcile.bat`

Either script finishes by opening four live log/port-forward windows — one each for the API, MLflow, Prefect, and Postgres.

---

## API Reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Redirects to the interactive Swagger UI (`/docs`) |
| `GET` | `/health` | Liveness + model-loaded status check |
| `POST` | `/reload-model` | Forces an immediate reload of the latest registered MLflow model |
| `GET` | `/predict/realtime/{store_id}` | Real-time single-store prediction via the Feast/Redis online store |

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
| `DATABASE_URL` | `postgresql://user:Password@postgres:5432/rossmann` | Postgres connection string (both the `asyncpg` and SQLAlchemy paths) |
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

## Security & Production-Readiness Notes

Deliberate shortcuts made to keep this a clear, runnable local/portfolio demo — flagged here explicitly rather than left implicit:

- Postgres credentials (`user` / `Password`) are hardcoded in plaintext in `deploy/docker-compose.yaml` and `deploy/terraform/main.tf` instead of being injected via Docker secrets or a Kubernetes `Secret`.
- All Kubernetes `Service` objects use `type: LoadBalancer`, which on a single-node K3s cluster simply exposes a NodePort-equivalent — there's no ingress controller, TLS termination, or authentication in front of any service.
- MLflow, Prefect, and Feast's registry all persist to dedicated Postgres databases rather than local SQLite/files — a real improvement over one shared database — but they're still all databases on the **same single Postgres instance**, so one Postgres outage takes down data, tracking, orchestration, and feature metadata together. MLflow model *artifacts* also still live on a single PVC-backed volume rather than an object store (S3/GCS), which won't horizontally scale past one node.
- The Prefect flow is triggered as an ad-hoc `subprocess` from the API process rather than as a scheduled/deployed Prefect flow run — fine for a single-node demo, but not how you'd want to trigger training in a multi-replica deployment.
- `monitoring/drift.py` supports `--fail-on-drift` for exactly this reason, but nothing currently calls it on a schedule — it has to be run by hand today.

---

## Roadmap

- [ ] Real `pytest` coverage for `src/`, `app/`, and `pipelines/` (CI currently only lints for fatal syntax errors)
- [ ] Move DVC remote storage from local disk to S3/GCS for true team-shared reproducibility
- [ ] Replace plaintext Postgres credentials with Kubernetes `Secret`s
- [ ] Convert the ad-hoc Prefect `subprocess` trigger into a proper scheduled/deployed Prefect flow run
- [ ] Add an Ingress + TLS in front of the Kubernetes services instead of raw `LoadBalancer` exposure
- [x] ~~Wire `monitoring/drift.py` into a scheduled job against live inference logs~~ — `drift.py` now reads live Postgres data, logs to MLflow, and supports `--fail-on-drift`; it just isn't *scheduled* anywhere yet
- [ ] Actually schedule `monitoring/drift.py` — a cron entry, a GitHub Actions job, or (most consistent with the rest of the stack) its own Prefect deployment that calls `--fail-on-drift` and triggers `pipelines/training_pipeline.py` on failure

---

## About

Built by **Youcef Benkeddad** ([@benkeddad](https://github.com/benkeddad)) as a hands-on demonstration of end-to-end MLOps engineering — data versioning, feature stores, orchestration, experiment tracking, container orchestration, and infrastructure as code, wired into one working, closed-loop system rather than shown as isolated pieces.
