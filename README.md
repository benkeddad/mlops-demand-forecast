# Rossmann Demand Forecasting — A Closed-Loop MLOps System

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

Feed this system one new row of sales data and step back. A database trigger fires. A training pipeline spins up in a subprocess. Three DVC stages run in sequence — ingest, featurize, train. A new XGBoost model gets logged to MLflow with full data lineage and registered under a named model. The FastAPI process reloads that model into memory. Every row in the `test` table still waiting on a prediction gets scored and written back to Postgres. All of it happens inside a couple of minutes, all of it is visible in the Prefect and MLflow dashboards, and none of it required a scheduler, a cron job, or a human typing a command.

That closed loop — not the individual tools — is the point of this repository: a demonstration that a Rossmann-style sales forecasting model can live inside a system that retrains, re-registers, and redeploys itself in response to its own data, using the same patterns a production ML platform team would reach for.

It ships as two independently runnable deployments of the identical five-service stack: a **Docker Compose** path for fast local iteration, and a **Terraform-provisioned Kubernetes (K3s)** path for a production-shaped runtime — both built from the same Dockerfiles, the same schema, and the same application code.

---

## Table of Contents

1. [System Architecture](#system-architecture)
2. [The Stack, by Layer](#the-stack-by-layer)
3. [Walkthrough — A Real-Time Prediction](#walkthrough--a-real-time-prediction)
4. [Walkthrough — A Retraining Cycle](#walkthrough--a-retraining-cycle)
5. [Feature Store Internals — Feast](#feature-store-internals--feast)
6. [Training, Tracking & Registry — MLflow + XGBoost](#training-tracking--registry--mlflow--xgboost)
7. [Drift Detection — Evidently](#drift-detection--evidently)
8. [Two Ways to Run This](#two-ways-to-run-this)
9. [Infrastructure as Code](#infrastructure-as-code)
10. [The Automation Scripts](#the-automation-scripts)
11. [Repository Map](#repository-map)
12. [Hard-Won Lessons](#hard-won-lessons)
13. [Getting It Running](#getting-it-running)
14. [API Surface](#api-surface)
15. [Configuration Reference](#configuration-reference)
16. [CI Pipeline](#ci-pipeline)
17. [Known Limitations](#known-limitations)
18. [What's Next](#whats-next)
19. [Author](#author)

---

## System Architecture

```mermaid
flowchart TB
    subgraph Client["Client"]
        REQ[HTTP Request]
    end

    subgraph App["Application Layer — FastAPI"]
        LISTEN["asyncpg LISTEN/NOTIFY loop<br/>(run_postgres_event_loop)"]
        ROUTES[REST Routes]
        MODEL[In-memory pyfunc model]
    end

    subgraph MLOps["Pipeline & Tracking Layer"]
        PRF[Prefect Server<br/>Rossmann-Enterprise-Pipeline]
        DVC["DVC: ingest → featurize → train"]
        MLF[MLflow Server<br/>Tracking + Model Registry]
        FS[Feast SDK<br/>offline/online feature store]
    end

    subgraph PGBox["PostgreSQL 15 — one instance, four databases"]
        direction LR
        PGAPP[("rossmann db<br/>train / test")]
        PGMLF[("mlflow db<br/>runs · params · metrics<br/>· registry")]
        PGPRF[("prefect db<br/>flow runs · task runs · logs")]
        PGFS[("feast db<br/>SQL registry")]
    end

    RD[(Redis 7<br/>Feast online store)]

    REQ --> ROUTES
    ROUTES -->|GET /predict/realtime| FS
    FS -->|reads| RD
    ROUTES --> MODEL
    MODEL -->|prediction JSON| ROUTES

    PGAPP -->|"pg_notify('train_changed')<br/>pg_notify('test_inserted')"| LISTEN
    LISTEN -->|subprocess.Popen| PRF
    PRF ==>|"persists every flow run<br/>and task run it executes"| PGPRF
    PRF --> DVC
    DVC -->|"SELECT * FROM train"| PGAPP
    DVC -->|feast apply / materialize| FS
    FS -->|"reads/writes entity &<br/>feature-view definitions"| PGFS
    FS -->|writes online features| RD
    DVC -->|log_model + register| MLF
    MLF ==>|"persists params, metrics, dataset<br/>lineage & registry entries"| PGMLF
    LISTEN -->|reload on subprocess exit| MLF
    MLF -->|pyfunc.load_model| MODEL
    MODEL -->|"UPDATE test SET predicted_sales"| PGAPP
```

PostgreSQL sits at the center of this diagram on purpose — and it's doing more than one job. It's the system of record for `train`/`test`, wired up with `pg_notify` triggers (`db/init.sql`) that make it double as an event bus for FastAPI's `asyncpg` listener. But it's also the **shared backend store for the two "servers" in the stack**: MLflow doesn't hold runs, params, metrics, or registry entries in memory or in a local file — every `mlflow.log_metric` / `mlflow.log_model` call is a write into its own `mlflow` database (the bold arrow above). Prefect works the same way against its own `prefect` database — every flow run and task run this system executes is durably persisted there, which is exactly what makes the Prefect UI's run history survive a container restart. Four logical databases, one physical Postgres instance, one connection string pattern reused everywhere.

---

## The Stack, by Layer

Every entry below traces to something real in the repo — a line in `requirements.txt`, a `FROM` in a Dockerfile, or a `required_providers` block in Terraform.

**Data & Storage Layer**
| Tool | What it's doing here |
|---|---|
| PostgreSQL 15 (`postgres:15-alpine`) | System of record for `train`/`test`; also hosts three more logical databases (`mlflow`, `prefect`, `feast`) on the same instance; source of the `pg_notify` events that drive the whole loop |
| Redis 7 (`redis:7-alpine`) | Feast's online store — the sub-10ms feature cache the real-time endpoint reads from |
| DVC `>=3.50.0` (+ `dvc-objects`, `pathspec` version floors added for Windows compatibility) | Content-hashes the `ingest → featurize → train` stage graph so nothing reruns unless its actual inputs changed |

**Feature & ML Layer**
| Tool | What it's doing here |
|---|---|
| Feast `feast[postgres,redis]` | Offline store = Postgres (point-in-time-correct training reads), online store = Redis, registry = a dedicated SQL database rather than a flat file |
| XGBoost `>=1.7.0` | `XGBRegressor` forecasting daily per-store sales, `objective="reg:squarederror"` |
| scikit-learn `>=1.2.0` | `train_test_split` for the validation split |
| pandas / NumPy / PyArrow | DataFrame transforms and fast Parquet I/O between DVC stages |
| MLflow `>=2.10.0` | Experiment tracking, dataset lineage (`mlflow.log_input`), and the Model Registry entry the API resolves at load time |

**Orchestration Layer**
| Tool | What it's doing here |
|---|---|
| Prefect 2 `>=2.14.0,<3.0.0` (self-hosted server) | Wraps the three DVC stages as a named, retryable flow with a run-history UI, persisting its own state to a dedicated `prefect` Postgres database |

**Serving Layer**
| Tool | What it's doing here |
|---|---|
| FastAPI `>=0.100.0` + Uvicorn `>=0.22.0` | Async web layer; runs a permanent background `LISTEN/NOTIFY` task alongside the request loop |
| Pydantic `>=2.0.0` | Request/response models |
| `watchdog` `>=3.0.0` | Backs Uvicorn's hot-reload; paired with `WATCHFILES_FORCE_POLLING=true` because file-change events don't reliably cross the Docker Desktop ↔ WSL2 volume boundary |

**Monitoring Layer**
| Tool | What it's doing here |
|---|---|
| Evidently `>=0.4.0,<0.7.0` | `DataDriftPreset` comparing the `train` and `test` populations, logged to its own MLflow experiment, with a `--fail-on-drift` exit code for automation |

**Infrastructure Layer**
| Tool | What it's doing here |
|---|---|
| Docker + Docker Compose | Three purpose-built images and a 5-service local stack |
| Kubernetes (K3s) | Single-binary Kubernetes distribution run natively inside WSL2 |
| Terraform (`hashicorp/kubernetes ~> 2.24.0`) | Declares every `Deployment`, `Service`, `PersistentVolumeClaim`, and `ConfigMap` the stack needs |
| GitHub Actions | Lints and test-gates every push/PR to `main` |

**Database Access Layer — three drivers, three different jobs**

This project doesn't standardize on a single Postgres client, because no single one covers all three access patterns it needs:

- **`asyncpg` (`==0.29.0`)** — the only one of the three with async `LISTEN/NOTIFY` support, which is what the FastAPI event loop is built on.
- **`psycopg2-binary` (`==2.9.0`)** — used specifically where a connection has to run in `AUTOCOMMIT` mode, because PostgreSQL refuses `CREATE DATABASE` inside a transaction block (`app/db_bootstrap.py`). MLflow's own server also uses this driver internally once it's added to its image.
- **SQLAlchemy `==2.0.0`** (with **`psycopg[binary,pool]`** underneath, unpinned) — the `create_engine()` layer that `pandas.read_sql` / `.to_sql` expect, used everywhere a script moves an entire table in or out of Postgres: `src/data.py`, `src/seed_db.py`, `src/predict_initial.py`, `monitoring/drift.py`.

Picking the tool that fits the access pattern instead of forcing one abstraction everywhere is a small decision, but it's the kind of decision that shows up in every mature data platform.

---

## Walkthrough — A Real-Time Prediction

Trace a single call to `GET /predict/realtime/{store_id}` through `app/main.py`:

1. **Feature lookup.** `feast_store.get_online_features(...)` is called with `entity_rows=[{"entity_id": store_id}]`. Because Feast's SDK is synchronous, it's run inside `asyncio.to_thread` so it doesn't block the event loop the `LISTEN/NOTIFY` listener also depends on.
2. **Cache miss handling.** If the store isn't present in Redis, the endpoint returns a `404` with an actionable message rather than a generic error — it tells the caller to run `feast materialize-incremental`.
3. **Feature alignment.** The returned feature vector is re-mapped through the same `StateHoliday` string-to-int encoding used at training time (`{"0": 0, "a": 1, "b": 2, "c": 3}`), then sliced into the exact column order the model was trained on: `["Store", "DayOfWeek", "Promo", "StateHoliday", "SchoolHoliday", "Year", "Month", "Day"]`.
4. **Inference.** `_model.predict(features_only)` — `_model` is the module-level `pyfunc` model loaded from MLflow at process startup (and whenever `/reload-model` or an automatic post-training reload fires).
5. **Response.** The endpoint echoes back the feature values it actually used, not just the number, so the caller can sanity-check what went into the prediction.

The whole path never touches PostgreSQL — it's a pure Redis read plus an in-memory model call, which is exactly the latency profile an online feature store exists to deliver.

---

## Walkthrough — A Retraining Cycle

This is the part that makes the system "closed-loop" rather than "has an ML pipeline."

```mermaid
sequenceDiagram
    participant PG as Postgres: rossmann db
    participant API as FastAPI listener
    participant PRF as Prefect Server
    participant PRFDB as Postgres: prefect db
    participant DVC as DVC stages
    participant MLF as MLflow Server
    participant MLFDB as Postgres: mlflow db

    Note over PG: INSERT / UPDATE / DELETE on train
    PG->>API: pg_notify('train_changed', 'update')
    API->>PRF: subprocess.Popen(training_pipeline.py)
    activate PRF
    PRF->>PRFDB: create flow run (Rossmann-Enterprise-Pipeline)
    PRF->>DVC: dvc repro --force ingest
    DVC->>PG: SELECT * FROM train → clean_data.parquet
    PRF->>PRFDB: log task run: ingest = Completed
    PRF->>DVC: dvc repro featurize
    DVC->>DVC: build_features() → feast apply → feast materialize
    PRF->>PRFDB: log task run: featurize = Completed
    PRF->>DVC: dvc repro train
    DVC->>MLF: log_model + register (Rossmann_XGBoost_Model)
    activate MLF
    MLF->>MLFDB: INSERT run params, metrics,<br/>dataset lineage, registry entry
    MLF-->>DVC: run + version confirmed
    deactivate MLF
    PRF->>PRFDB: log task run: train = Completed
    PRF->>PRFDB: mark flow run = Completed
    deactivate PRF
    PRF-->>API: subprocess process exits
    API->>MLF: pyfunc.load_model(models:/.../latest)
    MLF->>MLFDB: SELECT latest registry version
    MLF-->>API: model artifact
    API->>PG: perform_batch_prediction() as a background task
```

A few details worth calling out:

- The trigger is a Postgres **statement-level** trigger (`FOR EACH STATEMENT`), not row-level — one notification per write operation regardless of how many rows it touched, which keeps a bulk `seed_db.py` load from firing hundreds of thousands of retrains.
- `handle_train_db_trigger` doesn't `await` the subprocess directly on the main event loop — it hands the wait off to `asyncio.to_thread(process.wait)` inside `wait_and_reload`, so a multi-minute training run doesn't block the API from serving other requests.
- The `ingest` stage runs with `dvc repro --force`, deliberately bypassing DVC's cache check — because the actual change happened inside the Postgres table, which DVC has no visibility into, so "nothing changed on disk" would otherwise cause DVC to (correctly, but unhelpfully) skip the stage.
- The moment training finishes, the API doesn't just reload the model — it immediately fires a fresh batch-prediction pass in the background, so any rows sitting in `test` get scored against the model that was *just* registered, not the stale one from before.
- Notice `PRFDB` and `MLFDB` are drawn as separate participants but are the exact same Postgres server as `PG` under the hood — Prefect's flow/task-run bookkeeping and MLflow's run/registry bookkeeping are both durable database writes, not in-memory state that a container restart would wipe out.

---

## Feature Store Internals — Feast

`feature_repo/features.py` defines one entity and one feature view:

```python
store_entity = Entity(name="entity_id", join_keys=["entity_id"])

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

rossmann_features_view = FeatureView(
    name="rossmann_features",
    entities=[store_entity],
    ttl=timedelta(days=3650),
    source=rossmann_source,
)
```

Three design choices stand out:

- **The offline source is a live SQL query, not a static file.** Every time `feast apply` + `feast materialize` runs, it's reading the current state of `train` directly — there's no intermediate export step to go stale.
- **The registry is `registry_type: sql`, pointed at a dedicated `feast` Postgres database**, not Feast's default local file registry. That matters the moment more than one process needs to resolve feature definitions — a file registry baked into one container's filesystem doesn't survive a second replica or a redeploy against a fresh volume.
- **The TTL is ten years.** The Rossmann dataset's timestamps sit in 2013–2015; Feast's *default* lookback windows are tuned for genuinely live data and would silently exclude all of it, making materialization "succeed" into an empty Redis store. The explicit ten-year TTL, plus explicit-range `feast materialize 2010-01-01T00:00:00 2030-12-31T23:59:59` calls (rather than `materialize-incremental`, which inherits the same recency-biased default), sidesteps that trap entirely.

The same `build_features()` function (`src/features.py`) is used to shape data for training, for the batch prediction path, and for `monitoring/drift.py`'s comparisons — one transform, three consumers, which is what actually closes the training/serving skew gap that feature stores are supposed to solve.

---

## Training, Tracking & Registry — MLflow + XGBoost

`src/train.py` treats every training run as an artifact with full provenance, not just a metric log:

```python
mlflow.set_experiment("Rossmann_Sales_Forecasting")
with mlflow.start_run():
    dataset = mlflow.data.from_pandas(processed_df, source=processed_data_path)
    mlflow.log_input(dataset, context="training")      # exact data lineage

    model = get_model(n_estimators=150, max_depth=8)    # src/model.py factory
    model.fit(X_train, y_train)

    mlflow.log_metric("val_rmspe", rmspe_score)          # src/evaluate.py
    mlflow.xgboost.log_model(
        xgb_model=model,
        artifact_path="xgboost_model",
        registered_model_name="Rossmann_XGBoost_Model",
    )
```

The evaluation metric is **RMSPE** — Root Mean Square Percentage Error, the metric the original Rossmann Kaggle competition was scored on — with zero-sales days explicitly masked out of the denominator before the percentage error is computed, since a store with zero actual sales makes any percentage-based error undefined.

The API never references a specific run ID. It resolves `MODEL_URI = "models:/Rossmann_XGBoost_Model/latest"` — a live pointer into the Model Registry — so a brand-new registration becomes the one served on the very next reload, with zero redeployment.

---

## Drift Detection — Evidently

`monitoring/drift.py` is a standalone CLI, built to be dropped into a scheduler rather than run by hand in a notebook:

```bash
python monitoring/drift.py --reference-table train --current-table test \
    --drift-share-threshold 0.3 --fail-on-drift
```

What it actually does:

1. Pulls the `train` (reference) and `test` (current) populations from Postgres and runs **both** through the same `build_features()` transform training uses — so drift is measured against the model's real input schema, not a hand-rolled approximation of it.
2. Runs Evidently's `DataDriftPreset` across the shared feature columns.
3. Writes a timestamped HTML report to `monitoring/reports/` (each run keeps its own file — nothing gets overwritten).
4. Logs `drift_share`, `n_drifted_columns`, and `dataset_drift` as their own MLflow run inside a dedicated `data-drift-monitoring` experiment, separate from training runs but queryable in the same tracking server.
5. Exits non-zero when the drift share crosses the threshold — a real automation contract, ready to be wired into a cron job, a CI step, or its own Prefect deployment (nothing currently schedules it; see [What's Next](#whats-next)).

One quiet but real piece of engineering: `requirements.txt` pins `evidently>=0.4.0,<0.7.0`, with an inline comment explaining exactly why — `drift.py` reads Evidently's report via `report.as_dict()["metrics"][0]["result"]`, and Evidently's 0.7 release restructured that schema. The upper bound isn't boilerplate; it's a specific, previously-diagnosed breakage headed off before it could happen again.

---

## Two Ways to Run This

| | Docker Compose | Terraform + K3s |
|---|---|---|
| **Where it runs** | Any host with Docker Desktop | K3s inside WSL2 (Windows) |
| **How services are declared** | `deploy/docker-compose.yaml` | `deploy/terraform/main.tf` |
| **MLflow / Prefect images** | Built locally from `docker/mlflow.Dockerfile` / `docker/prefect.Dockerfile` | Same Dockerfiles, built then `docker save`'d into K3s' containerd cache |
| **Storage** | Named Docker volumes | `PersistentVolumeClaim`s (2Gi / 2Gi / 1Gi) |
| **Networking** | Docker bridge network | Kubernetes `LoadBalancer` Services |
| **Startup dependency handling** | `depends_on: condition: service_healthy` against a real `pg_isready` healthcheck | `depends_on` on the Terraform resources themselves, so `terraform apply`'s ordering mirrors the runtime dependency graph |
| **Best for** | Local iteration, hot-reload dev loop | A runtime that actually looks like Kubernetes |

Both paths converge on the same five services — `postgres`, `redis`, `mlflow`, `prefect`, and the API — built from the exact same three Dockerfiles. Nothing about the application code changes between them.

---

## Infrastructure as Code

`deploy/terraform/main.tf` (Terraform `>= 1.0.0`, provider `hashicorp/kubernetes ~> 2.24.0`) declares the full resource graph declaratively:

- **Three `PersistentVolumeClaim`s** — Postgres (2Gi), MLflow (2Gi), Prefect (1Gi) — each set with `wait_until_bound = false`, a deliberate fix for a K3s-specific provisioner deadlock (details in [Hard-Won Lessons](#hard-won-lessons)).
- **Four backing `Deployment` + `LoadBalancer Service` pairs** for Postgres, Redis, MLflow, and Prefect, all with `image_pull_policy = "IfNotPresent"` so images pre-imported into containerd are reused rather than re-fetched.
- **The `rossmann-api` `Deployment`**, which declares an explicit `depends_on` against all four backing services and mounts the *same* MLflow `PersistentVolumeClaim` the MLflow server itself writes to — letting the API read freshly registered model artifacts straight off the shared volume without needing an S3-compatible artifact store.

```hcl
resource "kubernetes_persistent_volume_claim" "postgres_data" {
  metadata { name = "postgres-data-pvc" }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "2Gi" } }
  }
  wait_until_bound = false  # avoids the K3s local-path provisioner deadlock
}
```

---

## The Automation Scripts

Four deployment scripts, not one — because "tear everything down and rebuild" and "just get me back to a running state" are genuinely different operations with different risk profiles:

| Script | What it does |
|---|---|
| `scripts\deploy_k3s_clean.bat` | Destructive full rebuild. Resets WSL2, starts a fresh K3s server, pre-pulls base images into containerd, builds and imports all three custom images, deletes every prior K8s resource **including PVCs**, then runs `terraform init && terraform apply`. Use for a first deploy or a genuinely clean slate. |
| `scripts\deploy_k3s_reconcile.bat` | Non-destructive recovery. Checks whether K3s is already running before starting it. Individually checks every ConfigMap, PVC, Service, and Deployment the stack needs, and only runs `terraform apply` if something's actually missing. Restarts only the Deployments that fail a `rollout status` check. Never touches PVCs or existing state. |
| `scripts\deploy_compose_clean.bat` | Full Compose teardown (`down --volumes --rmi all --remove-orphans`) followed by a no-cache rebuild and `up -d --force-recreate`. |
| `scripts\scriptsdeploy_compose_reconcile.bat` | Validates the Compose file, then `up -d` — starts anything missing or stopped, leaves everything healthy alone. |

Both K3s scripts also invoke `scripts\install_terraform.sh` automatically — a standalone shell script rather than inline batch-file logic, for a reason explained in [Hard-Won Lessons](#hard-won-lessons).

---

## Repository Map

```
mlops-demand-forecast/
├── app/
│   ├── main.py                # FastAPI app: LISTEN/NOTIFY loop, inference routes
│   └── db_bootstrap.py        # Idempotent "ensure these 4 databases exist" check
├── src/
│   ├── data.py                 # DVC "ingest" — pulls `train` from Postgres → parquet
│   ├── features.py             # DVC "featurize" — builds features, applies + materializes Feast
│   ├── model.py                 # XGBRegressor factory
│   ├── train.py                 # DVC "train" — trains, evaluates, registers to MLflow
│   ├── evaluate.py              # RMSPE metric
│   ├── predict_initial.py       # One-shot batch scoring pass at container bootstrap
│   └── seed_db.py               # Idempotent CSV → Postgres loader
├── pipelines/
│   └── training_pipeline.py     # Prefect flow wrapping the three DVC stages
├── feature_repo/
│   ├── feature_store.yaml       # Feast project config
│   ├── features.py              # Entity + FeatureView + PostgreSQLSource
│   └── materialize.py           # Standalone wide-window materialization utility
├── monitoring/
│   ├── drift.py                  # Postgres-driven drift monitor
│   └── reports/                  # Timestamped HTML drift reports
├── docker/
│   ├── api.Dockerfile             # FastAPI + pipeline image (python:3.9-slim)
│   ├── mlflow.Dockerfile          # Upstream MLflow + psycopg2-binary
│   ├── prefect.Dockerfile         # Upstream Prefect 2.14 + asyncpg
│   └── entrypoint.sh               # Container bootstrap sequence
├── db/
│   ├── init.sql                    # Schema + LISTEN/NOTIFY trigger definitions
│   └── create-databases.sql        # First-boot CREATE DATABASE for mlflow/prefect/feast
├── deploy/
│   ├── docker-compose.yaml         # 5-service local stack
│   └── terraform/main.tf            # Full K8s resource graph
├── scripts/                       # Deployment automation (see above)
├── .github/workflows/ci.yml        # Lint + test workflow
├── dvc.yaml                        # DVC stage graph
└── requirements.txt                 # Full dependency set
```

---

## Hard-Won Lessons

Grouped by where the pain actually came from.

**Kubernetes & containers**

- K3s runs on **containerd**, not Docker — a `docker build` alone never makes an image visible to it. Fixed with an explicit `docker save` → `k3s ctr -n k8s.io images import` step for every custom image.
- Neither the stock MLflow nor stock Prefect images ship a PostgreSQL driver. Pointing either at Postgres crashes immediately with a missing-module error. Fixed with two one-line custom Dockerfiles that add `psycopg2-binary` / `asyncpg` on top of the official base images.
- Terraform's default behavior is to wait for a `PersistentVolumeClaim` to reach `Bound` before proceeding — but K3s' local-path provisioner only binds a volume once a pod that *uses* the claim gets scheduled, which can't happen while Terraform is still blocked waiting on the PVC. A real deadlock. Fixed with `wait_until_bound = false` on every PVC.
- `docker-entrypoint-initdb.d` scripts run exactly once, against a completely empty data directory. On any redeploy against an existing volume, newly-added `CREATE DATABASE` statements silently never execute, and dependent services fail with "database does not exist." Fixed with `app/db_bootstrap.py` — an idempotent check-then-create step that runs on every API container start, not just the first.

**Windows & WSL2 tooling**

- `cmd.exe`'s delayed-expansion parser corrupts embedded bash: any `!` character inside a bash string passed through `wsl bash -c "..."` gets silently truncated along with everything after it. Fixed by extracting that logic into a standalone `install_terraform.sh` invoked from WSL2, instead of inlining it in a `.bat` file.
- A stale, malformed `/etc/apt/sources.list.d/hashicorp.list` blocked `apt-get update` entirely inside the WSL2 Ubuntu shell — breaking even unrelated installs like `unzip`. Fixed by force-removing the file before continuing.
- MLflow's server binds to `127.0.0.1` by default, making it unreachable from any other container or pod. Fixed with an explicit `--host 0.0.0.0`.
- Connection strings that worked as `localhost` on a single machine broke the moment services moved to separate containers/pods. Fixed by switching every default to Docker Compose / Kubernetes service DNS names.

**Data & ML correctness**

- `feast materialize-incremental` uses a recency-biased default lookback window; the Rossmann dataset's 2013–2015 timestamps fall entirely outside it, so materialization "succeeds" into an empty Redis store with no error raised. Fixed by switching to explicit-range `feast materialize 2010-01-01T00:00:00 2030-12-31T23:59:59`.
- Postgres columns are lowercase (`stateholiday`, `dayofweek`); the model was trained on PascalCase feature names. Fixed with one consistent rename map applied at every ingestion, training, and inference boundary — including the real-time Feast path.
- Feature-order mismatches produce plausible-looking but wrong predictions instead of an error. The batch path explicitly slices and reorders columns into the exact training-time order before calling `.predict()`, and logs a warning if an entire batch comes back as a single repeated value.
- Evidently's 0.7 release restructured the report schema `drift.py` depends on. Rather than get surprised by it, `requirements.txt` pins an explicit upper bound with an inline comment explaining why.

---

## Getting It Running

### Prerequisites (Windows + WSL2)

The Kubernetes/Terraform path targets Windows with WSL2. (The Docker Compose path only needs Docker Desktop and Python, and is cross-platform.) These are the exact install steps that were followed to get this stack running from a clean Windows machine, in order.

**Step 1 — Install WSL2 and Ubuntu**

From an elevated (Administrator) PowerShell:

```powershell
wsl --install -d Ubuntu
```

This may require a restart. On first launch, the Ubuntu terminal prompts you to create a UNIX username and password — remember the password, it's required for `sudo`. Then set Ubuntu as the default distribution:

```powershell
wsl --set-default Ubuntu
```

**Step 2 — Install Docker Desktop (with WSL2 integration)**

Docker on Windows is managed by Docker Desktop, which bridges the `docker` CLI directly into Ubuntu — Docker is not installed natively inside the WSL2 distro.

1. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).
2. During install, check **"Use WSL 2 instead of Hyper-V."**
3. Open Docker Desktop → **Settings → Resources → WSL Integration**.
4. Enable the toggle for **Ubuntu**.
5. Click **Apply & Restart**.

**Step 3 — Install Python, K3s, and Terraform inside Ubuntu**

Open the Ubuntu terminal and run:

```bash
# Python 3 + build tools
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y python3 python3-pip python3-venv build-essential

# K3s (lightweight Kubernetes)
curl -sfL https://get.k3s.io | sh -
```

For Terraform, you can either follow HashiCorp's standard apt-repository install:

```bash
sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
```

...or skip this step entirely — `scripts\install_terraform.sh` handles it automatically (via a direct binary download rather than the apt route) every time `deploy_k3s_clean.bat` or `deploy_k3s_reconcile.bat` runs, and does nothing if Terraform is already installed.

> Reference Python version: the API image and CI both pin **Python 3.9** — match it locally if you're running anything outside a container.

### Then: Pick a Path

**Docker Compose — fastest for local iteration:**

```bash
git clone https://github.com/benkeddad/mlops-demand-forecast.git
cd mlops-demand-forecast
scripts\deploy_compose_clean.bat        :: first run / full rebuild
scripts\scriptsdeploy_compose_reconcile.bat   :: subsequent runs
```

Once healthy: API docs at `http://localhost:8000/docs`, MLflow at `http://localhost:5000`, Prefect at `http://localhost:4200`, Postgres at `localhost:5432`.

**Terraform + K3s — production-shaped runtime:**

After the prerequisites above, with Docker Desktop running, right-click and **Run as Administrator**:

```bat
scripts\deploy_k3s_clean.bat        :: first deploy / clean slate
scripts\deploy_k3s_reconcile.bat    :: subsequent runs / recovery
```

Either script opens four live log/port-forward windows for the API, MLflow, Prefect, and Postgres when it finishes.

---

## API Surface

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Redirects to the Swagger UI (`/docs`) |
| `GET` | `/health` | Liveness + model-loaded status |
| `POST` | `/reload-model` | Forces an immediate reload of the latest registered MLflow model |
| `GET` | `/predict/realtime/{store_id}` | Real-time single-store prediction via the Feast/Redis online store |

```bash
curl http://localhost:8000/health
curl http://localhost:8000/predict/realtime/1
curl -X POST http://localhost:8000/reload-model
```

Batch prediction has no manually-called endpoint by design — it's triggered automatically by new rows in `test`, or immediately after a retraining cycle finishes.

---

## Configuration Reference

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | `postgresql://user:Password@postgres:5432/rossmann` | Postgres connection string (both the `asyncpg` and SQLAlchemy paths) |
| `MODEL_URI` | `models:/Rossmann_XGBoost_Model/latest` | MLflow Model Registry URI resolved at load/reload time |
| `MLFLOW_TRACKING_URI` | `http://mlflow:5000` | MLflow tracking + registry endpoint |
| `PREFECT_API_URL` | `http://prefect:4200/api` | Prefect server API endpoint |
| `WATCHFILES_FORCE_POLLING` | `true` | Forces filesystem-change polling for reliable hot-reload across the Docker Desktop/WSL2 volume boundary |

---

## CI Pipeline

`.github/workflows/ci.yml`, on every push/PR to `main`:

1. Checks out the repo, sets up **Python 3.9**.
2. Installs `flake8`, `pytest`, and `requirements.txt`.
3. Lints with `flake8 --select=E9,F63,F7,F82` — fatal syntax errors and undefined names only, so the build fails fast on genuinely broken code rather than style nitpicks.
4. Runs `pytest` (currently a placeholder — real coverage is on the roadmap).

---

## Known Limitations

Deliberate shortcuts, flagged explicitly rather than left for someone else to discover:

- Postgres credentials are hardcoded in plaintext in `deploy/docker-compose.yaml` and `deploy/terraform/main.tf`, rather than injected via Docker secrets or a Kubernetes `Secret`.
- Every Kubernetes `Service` is `type: LoadBalancer`, which on a single-node K3s cluster is effectively a NodePort — there's no ingress controller, TLS termination, or auth in front of anything.
- MLflow, Prefect, and Feast's registry each have their own Postgres database, but all four databases live on the **same single Postgres instance** — one outage takes down data, tracking, orchestration, and feature metadata together. MLflow's model artifacts also sit on a single PVC rather than an object store, which won't scale past one node.
- Training is triggered as an ad-hoc `subprocess` from the API process, not a scheduled/deployed Prefect flow run — fine for a single-node demo, not how you'd trigger training behind a multi-replica API.
- `monitoring/drift.py` supports `--fail-on-drift` specifically so it can be automated, but nothing currently calls it on a schedule.

---

## What's Next

- [ ] Real `pytest` coverage for `src/`, `app/`, and `pipelines/`
- [ ] DVC remote storage on S3/GCS instead of local disk, for team-shared reproducibility
- [ ] Kubernetes `Secret`s instead of plaintext Postgres credentials
- [ ] A proper scheduled/deployed Prefect flow run instead of the ad-hoc `subprocess` trigger
- [ ] Ingress + TLS in front of the Kubernetes services
- [ ] Actually schedule `monitoring/drift.py` — cron, a GitHub Actions job, or its own Prefect deployment that calls `--fail-on-drift` and triggers `pipelines/training_pipeline.py` on failure

---

## Author

Built by **Youcef Benkeddad** ([@benkeddad](https://github.com/benkeddad)) as an end-to-end demonstration of MLOps engineering — data versioning, feature stores, orchestration, experiment tracking, container orchestration, and infrastructure as code, wired into one working, closed-loop system.
