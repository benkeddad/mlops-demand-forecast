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

Feed this system one new row of sales data and step back. A database trigger fires. A training pipeline spins up as a real Prefect deployment run. Three DVC stages run in sequence — ingest, featurize, train. A new XGBoost model gets logged to MLflow with full data lineage and registered under a named model. The FastAPI process reloads that model into memory. Every row in the `test` table still waiting on a prediction gets scored and written back to Postgres. All of it happens inside a couple of minutes, all of it is visible in the Prefect and MLflow dashboards, and none of it required a scheduler, a cron job, or a human typing a command.

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
    LISTEN -->|"run_deployment()"| PRF
    PRF ==>|"persists every flow run<br/>and task run it executes"| PGPRF
    PRF --> DVC
    DVC -->|"SELECT * FROM train"| PGAPP
    DVC -->|feast apply / materialize| FS
    FS -->|"reads/writes entity &<br/>feature-view definitions"| PGFS
    FS -->|writes online features| RD
    DVC -->|log_model + register| MLF
    MLF ==>|"persists params, metrics, dataset<br/>lineage & registry entries"| PGMLF
    LISTEN -->|reload on flow run completion| MLF
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
| DVC `[s3]==3.67.1` (+ `dvc-s3==3.3.0`, `aiobotocore==2.26.0`, `botocore>=1.41.0,<1.41.6` pinned as an exact chain, `dvc-objects`/`pathspec` version floors for Windows compatibility — see [Hard-Won Lessons](#hard-won-lessons)) | Content-hashes the `ingest → featurize → train` stage graph so nothing reruns unless its actual inputs changed; the `[s3]` extra plus `.dvc/config`'s `storage` remote let `dvc push`/`dvc pull` share cached artifacts with a team instead of staying local-disk-only. `docker/entrypoint.sh` also points this remote at LocalStack automatically at container boot (reusing MLflow's own `MLFLOW_S3_ENDPOINT_URL`/`AWS_*` env vars) and `pipelines/training_pipeline.py` runs an explicit `dvc push` task after every training run, so DVC-tracked data lands in S3 with no manual step |

**Feature & ML Layer**
| Tool | What it's doing here |
|---|---|
| Feast `feast[postgres,redis]` | Offline store = Postgres (point-in-time-correct training reads), online store = Redis, registry = a dedicated SQL database rather than a flat file |
| XGBoost `>=1.7.0` | `XGBRegressor` forecasting daily per-store sales, `objective="reg:squarederror"` |
| scikit-learn `>=1.2.0` | `train_test_split` for the validation split |
| pandas / NumPy / PyArrow | DataFrame transforms and fast Parquet I/O between DVC stages |
| MLflow `>=2.10.0` + `boto3==1.41.5` (pinned to the same `botocore` range DVC's `[s3]` chain needs — see [Hard-Won Lessons](#hard-won-lessons)) | Experiment tracking, dataset lineage (`mlflow.log_input`), and the Model Registry entry the API resolves at load time; the actual model artifacts (`model.xgb`, `MLmodel`, etc. — not run metadata, which stays in Postgres) are written directly to an S3-compatible bucket via `MLFLOW_S3_ENDPOINT_URL`/`AWS_*` env vars instead of the local filesystem |

**Orchestration Layer**
| Tool | What it's doing here |
|---|---|
| Prefect 2 `>=2.14.0,<2.15.0` (self-hosted server; client pinned to the server's exact minor version — see [Hard-Won Lessons](#hard-won-lessons)) + `griffe<1.0.0` | Wraps the three DVC stages as a named, retryable flow with a run-history UI, persisting its own state to a dedicated `prefect` Postgres database |

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
| Docker + Docker Compose | Three purpose-built images and a 5-service local stack, with credentials sourced from a gitignored `deploy/.env` |
| Kubernetes (K3s) | Single-binary Kubernetes distribution run natively inside WSL2 |
| Terraform (`hashicorp/kubernetes ~> 2.24.0`, `hashicorp/tls ~> 4.0`) | Declares every `Deployment`, `Service`, `PersistentVolumeClaim`, `ConfigMap`, `Secret`, and `Ingress` the stack needs |
| GitHub Actions | `ci.yml` lints and test-gates every push/PR to `main`; `drift-monitoring.yml` runs `monitoring/drift.py` on a daily schedule |

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
    participant S3 as S3 (LocalStack)

    Note over PG: INSERT / UPDATE / DELETE on train
    PG->>API: pg_notify('train_changed', 'update')
    API->>PRF: run_deployment("Rossmann-Enterprise-Pipeline/production")
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
    MLF->>S3: PUT model.xgb, MLmodel, conda.yaml, ...
    MLF->>MLFDB: INSERT run params, metrics,<br/>dataset lineage, registry entry
    MLF-->>DVC: run + version confirmed
    deactivate MLF
    PRF->>PRFDB: log task run: train = Completed
    PRF->>DVC: dvc push
    DVC->>S3: PUT content-hashed clean_data.parquet, train_features.parquet
    PRF->>PRFDB: log task run: push = Completed
    PRF->>PRFDB: mark flow run = Completed
    deactivate PRF
    PRF-->>API: flow run reaches a terminal state (polled via read_flow_run)
    API->>MLF: pyfunc.load_model(models:/.../latest)
    MLF->>MLFDB: SELECT latest registry version
    MLF->>S3: GET model.xgb, MLmodel, ...
    MLF-->>API: model artifact
    API->>PG: perform_batch_prediction() as a background task
```

A few details worth calling out:

- The trigger is a Postgres **statement-level** trigger (`FOR EACH STATEMENT`), not row-level — one notification per write operation regardless of how many rows it touched, which keeps a bulk `seed_db.py` load from firing hundreds of thousands of retrains.
- `handle_train_db_trigger` doesn't block the main event loop waiting for training to finish — `trigger_training_run()` calls `run_deployment(..., timeout=0)`, which returns the new flow run's id immediately, then hands the actual wait off to `wait_and_reload_deployment_run()` as a separate background task that polls the Prefect API every few seconds, so a multi-minute training run doesn't block the API from serving other requests.
- The `ingest` stage runs with `dvc repro --force`, deliberately bypassing DVC's cache check — because the actual change happened inside the Postgres table, which DVC has no visibility into, so "nothing changed on disk" would otherwise cause DVC to (correctly, but unhelpfully) skip the stage.
- The moment training finishes, the API doesn't just reload the model — it immediately fires a fresh batch-prediction pass in the background, so any rows sitting in `test` get scored against the model that was *just* registered, not the stale one from before.
- Notice `PRFDB` and `MLFDB` are drawn as separate participants but are the exact same Postgres server as `PG` under the hood — Prefect's flow/task-run bookkeeping and MLflow's run/registry bookkeeping are both durable database writes, not in-memory state that a container restart would wipe out.
- `run_deployment("Rossmann-Enterprise-Pipeline/production")` targets a real Prefect Deployment, not the flow function directly — it's registered once at API startup by a second long-lived subprocess (`pipelines/serve_deployment.py`, launched from `app/main.py`'s `lifespan`) calling `flow.serve(name="production")`. The same deployment is reachable from `POST /trigger-training` for manual/automated triggers outside the DB-write path (see [API Surface](#api-surface)), and can optionally be put on a cron schedule via `TRAINING_SCHEDULE_CRON` on top of the DB trigger.
- `S3` is the same LocalStack instance for both DVC and MLflow, but two separate buckets (`rossmann-mlops-dvc-store`, `rossmann-mlflow-artifacts`) and two very different write paths: MLflow writes to S3 *synchronously, inside* `log_model()` — the moment training finishes, the artifact is already there. DVC's `dvc repro` never talks to a remote at all; it only ever touches the local cache. That's why `dvc push` is its own explicit 4th Prefect task (`pipelines/training_pipeline.py`) run once training completes, not something that happens automatically as a side effect of the other three stages.

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
| **Storage** | Named Docker volumes, plus an S3-compatible LocalStack bucket for MLflow artifacts | `PersistentVolumeClaim`s (2Gi / 2Gi / 1Gi), plus the same LocalStack S3 bucket for MLflow artifacts |
| **Networking** | Docker bridge network | Kubernetes `LoadBalancer` Services |
| **Startup dependency handling** | `depends_on: condition: service_healthy` against a real `pg_isready` healthcheck | `depends_on` on the Terraform resources themselves, so `terraform apply`'s ordering mirrors the runtime dependency graph |
| **Best for** | Local iteration, hot-reload dev loop | A runtime that actually looks like Kubernetes |

Both paths converge on the same five services — `postgres`, `redis`, `mlflow`, `prefect`, and the API — built from the exact same three Dockerfiles. Nothing about the application code changes between them.

---

## Infrastructure as Code

`deploy/terraform/main.tf` (Terraform `>= 1.0.0`, providers `hashicorp/kubernetes ~> 2.24.0` and `hashicorp/tls ~> 4.0`) declares the full resource graph declaratively:

- **Three `PersistentVolumeClaim`s** — Postgres (2Gi), MLflow (2Gi), Prefect (1Gi) — each set with `wait_until_bound = false`, a deliberate fix for a K3s-specific provisioner deadlock (details in [Hard-Won Lessons](#hard-won-lessons)). The MLflow PVC is still mounted, but is now effectively legacy storage: MLflow only ever resolves it for experiments that existed *before* the S3 migration below — every experiment created since writes straight to S3 instead (see [Hard-Won Lessons](#hard-won-lessons) for why that's an MLflow-wide rule, not a config toggle).
- **Four backing `Deployment` + `LoadBalancer Service` pairs** for Postgres, Redis, MLflow, and Prefect, all with `image_pull_policy = "IfNotPresent"` so images pre-imported into containerd are reused rather than re-fetched.
- **A `kubernetes_secret` (`s3-credentials`)** plus a `localstack_endpoint` variable, feeding MLflow's `--default-artifact-root` (`s3://rossmann-mlflow-artifacts/mlflow-artifacts` instead of the old PVC path) and matching `MLFLOW_S3_ENDPOINT_URL`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION` env vars on both the `mlflow` and `rossmann-api` Deployments. The endpoint value is deliberately the K3s node's real IP, not `127.0.0.1`/`localhost` (see [Hard-Won Lessons](#hard-won-lessons)).
- **The `rossmann-api` `Deployment`**, which declares an explicit `depends_on` against all four backing services. It still mounts the same MLflow `PersistentVolumeClaim` the MLflow server writes to, purely for backward compatibility with pre-migration model versions — freshly registered models are resolved straight from S3 via `mlflow.pyfunc.load_model()`, which is why the API needs the exact same `s3-credentials` `Secret` MLflow does.
- **A `kubernetes_secret` (`postgres-credentials`)** holding the raw Postgres user/password/db plus three pre-composed connection strings (`API_DATABASE_URL`, `MLFLOW_BACKEND_STORE_URI`, `PREFECT_DB_URL`) — every Deployment above reads its credentials via `secret_key_ref` instead of a literal `value`. MLflow's connection string lives inside a CLI arg rather than a discrete env var, so it's threaded through with Kubernetes' native `$(VAR_NAME)` command-substitution syntax instead.
- **A self-signed TLS certificate (`hashicorp/tls` provider) + `kubernetes_ingress_v1`** fronting the API, MLflow, and Prefect UIs as name-based virtual hosts (`api.rossmann.local`, `mlflow.rossmann.local`, `prefect.rossmann.local`) through K3s' built-in Traefik ingress controller — added alongside the existing `LoadBalancer` Services, not instead of them, so nothing that already worked stops working.

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

Four deployment scripts, not eight — "tear everything down and rebuild" vs. "just get me back to a running state" are genuinely different operations with different risk profiles, for each of the two deploy paths (Compose, K3s). There used to be a second, Docker-Desktop-CLI-driven copy of each script too, but they were removed: LocalStack — required for MLflow/DVC's S3 storage, not optional (see below) — only ever runs inside WSL2 in this project, so every one of these four scripts already needs a working WSL2 Docker Engine regardless. A Docker-Desktop-only variant never actually avoided the WSL2 dependency, it just skipped the faster build path. **Docker Desktop is still required, but purely to view/monitor containers** — install it with WSL Integration enabled and use its Containers/Images dashboard to inspect whatever WSL2's own Docker Engine builds and runs; the *building and running* itself always happens through WSL2 now.

| Script | What it does |
|---|---|
| `scripts\deploy_k3s_clean_wsl.bat` | Destructive full rebuild. Resets WSL2, starts a fresh K3s server, pre-pulls base images into containerd, builds and imports all three custom images (via WSL2's own Docker Engine), deletes every prior K8s resource **including PVCs**, then runs `terraform init && terraform apply`. Use for a first deploy or a genuinely clean slate. |
| `scripts\deploy_k3s_reconcile_wsl.bat` | Non-destructive recovery. Checks whether K3s is already running before starting it. Individually checks every ConfigMap, PVC, Service, and Deployment the stack needs, and only runs `terraform apply` if something's actually missing. Restarts only the Deployments that fail a `rollout status` check. Never touches PVCs or existing state. |
| `scripts\deploy_compose_clean_wsl.bat` | Full Compose teardown (`down --volumes --rmi all --remove-orphans`) followed by a no-cache rebuild and `up -d --force-recreate`, with every `docker compose` command run inside WSL2 against Ubuntu's own Docker Engine. Must be run **as Administrator** — it needs elevated rights to map the ports Compose opens inside WSL back to Windows `localhost`. |
| `scripts\deploy_compose_reconcile_wsl.bat` | Validates the Compose file, then `up -d` — starts anything missing or stopped, leaves everything healthy alone. Also requires **Administrator**, for the same localhost port-mapping reason as its clean counterpart. |

Both K3s scripts also invoke `scripts\install_terraform.sh` automatically — a standalone shell script rather than inline batch-file logic, for a reason explained in [Hard-Won Lessons](#hard-won-lessons).

All four scripts also run `scripts\setup_localstack_bucket.sh` early on. It's a best-effort step: if [LocalStack](https://www.localstack.cloud/) is already running it's used as-is; if it's installed but stopped, the script starts it; if it isn't installed at all, or the AWS CLI is missing, the step just logs that and moves on **without failing the whole deploy** — but see below for why you actually want it installed, not skipped. When LocalStack is reachable, the script idempotently creates the two S3 **buckets** both DVC and MLflow need (`rossmann-mlops-dvc-store`, `rossmann-mlflow-artifacts`) — and that's *all* it creates. Neither DVC nor MLflow needs any "folder" (S3 prefix) pre-created inside those buckets: S3 has no real directory structure, a prefix simply starts existing the instant the first object is written under it, so `dvc push` and `mlflow.log_model()` create their own `dvc-store/...` / `mlflow-artifacts/...` layout automatically the first time each one actually runs. There's nothing else to provision, and nothing pre-creates empty folders that would just sit there unused.

**Install LocalStack and the AWS CLI before your first deploy — this is a required prerequisite now, not an optional convenience.** Both buckets are load-bearing for the live containers themselves: MLflow's `mlflow`/`rossmann-api` Deployments write/read model artifacts straight to `s3://rossmann-mlflow-artifacts/...`, and `docker/entrypoint.sh`/`pipelines/training_pipeline.py` automatically configure and push DVC-tracked data to `s3://rossmann-mlops-dvc-store/...` on every training run (see [Hard-Won Lessons](#hard-won-lessons)). Skip this and the containers still start, but the first real training run fails loudly: `MLFLOW_S3_ENDPOINT_URL` is always set regardless (Terraform/Compose inject it unconditionally), so with no real LocalStack behind it, both MLflow's `log_model()` and the `dvc_push` task hit real connection errors instead of a graceful no-op — `dvc_push` in particular uses the same `check=True` hard-failure behavior as the other three pipeline stages once an endpoint is configured, it does not swallow real failures.

Install both CLIs inside the WSL2 Ubuntu distro (not Windows — every script here runs LocalStack via `wsl bash`):

```bash
pip3 install localstack awscli
```

LocalStack itself then runs as a Docker container under the hood (`localstack start -d`), so it needs the same WSL2 Docker Engine from [Step 2](#prerequisites-windows--wsl2) below — nothing extra to install for that part. One caveat carried over from earlier hands-on debugging: LocalStack's own persistence feature is *not* enabled here (see [Known Limitations](#known-limitations)) — recreating the LocalStack container itself (not just restarting a deploy script) wipes both buckets, at which point `setup_localstack_bucket.sh` recreating two empty buckets is necessary but not sufficient; training has to actually run again to repopulate them.

---

## Repository Map

```
mlops-demand-forecast/
├── app/
│   ├── main.py                # FastAPI app: LISTEN/NOTIFY loop, inference routes, Prefect Deployment trigger
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
│   ├── training_pipeline.py     # Prefect flow wrapping the three DVC stages
│   └── serve_deployment.py      # Long-lived Prefect Deployment server (flow.serve) — see Walkthrough: A Retraining Cycle
├── tests/                       # Real pytest coverage for src/, app/, and pipelines/
├── pytest.ini                    # pythonpath wiring so both import styles used across the repo resolve under pytest
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
│   ├── docker-compose.yaml         # 5-service local stack (reads deploy/.env for credentials)
│   ├── .env.example                 # Committed shape for deploy/.env (gitignored, holds the real values)
│   └── terraform/main.tf            # Full K8s resource graph, incl. Secret + Ingress/TLS
├── scripts/                       # Deployment automation, Docker Desktop + WSL-native Docker variants (see above)
├── .github/workflows/
│   ├── ci.yml                      # Lint + real pytest suite, on every push/PR
│   └── drift-monitoring.yml        # Scheduled monitoring/drift.py run + retraining hook
├── .dvc/config                     # DVC S3 remote definition (team-shared reproducibility)
├── .gitignore                      # Keeps k3s.yaml, tfstate, deploy/.env, DVC cache, etc. out of version control
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
- The `deploy_k3s_clean*.bat` scripts wipe `terraform.tfstate` and then manually `kubectl delete` a hardcoded list of resources before re-applying — but `wsl --shutdown` doesn't actually clear K3s's persisted cluster data, only WSL subsystem state, so any resource *not* in that list (like the `Secret`/`Ingress` added later) survives as an orphan the freshly-wiped Terraform state no longer tracks, and the next `terraform apply` fails with "already exists." Fixed by keeping that delete list in sync with `main.tf`'s actual resources.

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

**Python dependency pinning**

- `aiobotocore` (pulled in transitively by `dvc[s3]`'s `dvc-s3` plugin) re-pins a different, narrow `botocore` version range on almost every release, while `dvc[s3]` itself left that whole chain unbounded. On a *fresh* install — every `docker build`, since the image has no pre-existing site-packages to short-circuit resolution against — pip's resolver tries dozens of `aiobotocore` releases, downloading a fresh ~14.6MB `botocore` wheel per attempt, looking like it hangs forever. Fixed by pinning the entire verified-working chain explicitly: `dvc[s3]==3.67.1`, `dvc-s3==3.3.0`, `aiobotocore==2.26.0`, `botocore>=1.41.0,<1.41.6`.
- `docker/prefect.Dockerfile` pins the **server** to Prefect 2.14, but `requirements.txt` originally left the **client** (API image) floating on `>=2.14.0,<3.0.0` — which resolved to 2.20.x, six minor versions ahead. The newer client's deployment-creation payload includes fields (`paused`, `schedules`) the older server's API schema rejects outright with a `422 Unprocessable Entity`, breaking `pipelines/serve_deployment.py`'s `flow.serve()`. Pinning the client back to `<2.15.0` to match then surfaced a second, previously-hidden problem: Prefect 2.14's own code imports `griffe.dataclasses`, a module a later `griffe` major release removed entirely — fixed with an explicit `griffe<1.0.0`. Both fixes were verified live against a running K3s deployment, not just locally.
- `docker/api.Dockerfile` used to `COPY .dvc/ .dvc/` wholesale, which — since no `.dockerignore` excludes it — silently baked the gitignored, host-only `.dvc/config.local` (LocalStack endpoint + dummy credentials) into the image. Harmless but pointless: `127.0.0.1` inside a container's own network namespace refers to *that container*, not the WSL host LocalStack actually listens on, so the copied-in override could never resolve (verified live — a container-side request to it raises `ConnectionRefusedError`). Fixed to `COPY .dvc/config .dvc/config`, copying only the real, portable, committed remote pointer.

**MLflow / S3 artifact migration**

- `dvc repro` (the command every pipeline stage runs) never talks to a remote at all — it only reads/writes the local `.dvc/cache`. Getting data into S3 needs a separate, explicit `dvc push`, unlike MLflow's `log_model()`, which writes to its configured artifact store synchronously as part of the same call. Easy to miss because nothing errors without it — DVC's own CLI output even prints a "Use `dvc push` to send your updates to remote storage" hint after every `repro`, which is easy to read as informational rather than as a to-do. Fixed by adding a 4th Prefect task (`dvc_push`) to `pipelines/training_pipeline.py`, run after `dvc_train` on every pipeline execution.
- The committed `.dvc/config` intentionally has no endpoint override (so it stays portable to real AWS), which meant DVC's S3 remote had no working endpoint *inside a container* at all — `.dvc/config.local` (the correct place for that) was deliberately kept out of the image for the exact reason in the entry above about `127.0.0.1`. Fixed by generating `.dvc/config.local` dynamically in `docker/entrypoint.sh` at every container boot, via `dvc remote modify --local`, reusing the exact same `MLFLOW_S3_ENDPOINT_URL`/`AWS_*` env vars already injected for MLflow — no new Secret, no baked-in machine-specific file, and it degrades gracefully (skips entirely) if those env vars aren't set.
- LocalStack (used for local S3 testing) defaults to binding port `4566` on `127.0.0.1` only — the same class of bug as the MLflow one above, just one network hop further out: not even the K3s node's own real IP could reach it, because a `127.0.0.1`-only bind means only *that same network namespace* can connect, and a K3s pod's namespace is never the WSL host's. Verified live with two separate `ConnectionRefusedError`s (via `127.0.0.1` and via the node IP) before the fix. Fixed by recreating the container with `-p 4566:4566` (all interfaces) instead of `-p 127.0.0.1:4566:4566`. Trade-off discovered the hard way: LocalStack's own persistence feature was never actually turned on (its `/_localstack/health` endpoint reported `"persistence": "disabled"` the whole time), so recreating the container wiped every bucket that existed under the old binding — worth confirming persistence is genuinely on before relying on a LocalStack container surviving a recreate.
- MLflow records each experiment's `artifact_location` once, at experiment-creation time, and never revisits it — pointing the *server's* `--default-artifact-root` at a new S3 bucket does nothing for experiments that already existed beforehand. `src/train.py`'s `mlflow.set_experiment("Rossmann_Sales_Forecasting")` kept resolving to its original local PVC path even after the server-wide default moved to S3 — training kept "succeeding" the entire time, with no error or warning, just artifacts silently continuing to land in the old location. Verified live via the run's own recorded `artifact_uri` (still `/mlflow/artifacts/...`, not `s3://...`, immediately after the migration). Fixed by renaming to a new experiment (`Rossmann_Sales_Forecasting_v2`), which — never having existed before — correctly inherits the server's current artifact root on first use. The old experiment and its run/model history are untouched, just no longer written to.

**Secrets, config & scheduling**

- `dvc init --force` unconditionally recreates `.dvc/`, wiping any already-committed `.dvc/config` — including the S3 remote. Since `docker/entrypoint.sh` used to run `dvc init --no-scm --force` on *every* container boot, adding a real committed remote first required making that step conditional (`[ ! -d ".dvc" ]`) so a live container never re-initializes over its own baked-in config.
- Docker Compose's automatic `.env` loading is resolved relative to **the directory of the first `-f`/`--file` Compose file**, not the shell's current working directory — easy to get backwards, since every deploy script here invokes `docker-compose -f deploy\docker-compose.yaml` from the repo root. `deploy/.env` (not a repo-root `.env`) is the file Compose actually reads for `${POSTGRES_PASSWORD}`-style substitution in `deploy/docker-compose.yaml`.
- A Kubernetes Secret can't be referenced from *inside* a `command`/`args` string the way a shell would with `$VAR` — MLflow's `--backend-store-uri` flag needed the connection string composed once, in Terraform, into a single secret key (`MLFLOW_BACKEND_STORE_URI`), then injected into `args` via Kubernetes' own `$(VAR_NAME)` command-substitution syntax rather than string-concatenating secret fragments at the Kubernetes level.

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

Docker on Windows is normally managed by Docker Desktop, which bridges the `docker` CLI directly into Ubuntu without installing a separate engine there.

1. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).
2. During install, check **"Use WSL 2 instead of Hyper-V."**
3. Open Docker Desktop → **Settings → Resources → WSL Integration**.
4. Enable the toggle for **Ubuntu**.
5. Click **Apply & Restart**.

Docker Desktop is required regardless of which deployment scripts you use — K3s itself, and the plain (non-`_wsl`) scripts, depend on it being installed and running.

**Optional — also install Docker natively inside WSL2, for the `_wsl` scripts**

The `_wsl` variants of every script in [The Automation Scripts](#the-automation-scripts) (`deploy_k3s_clean_wsl.bat`, `deploy_compose_reconcile_wsl.bat`, etc.) run their `docker build`/`docker compose` steps against a **second, independent Docker Engine installed directly inside the WSL2 Ubuntu distro** — not Docker Desktop's — because builds run faster when the build context and image layers never have to cross the Windows↔WSL2 filesystem boundary. To use those scripts, install Docker inside Ubuntu itself:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

(Log out of the Ubuntu shell and back in, or run `newgrp docker`, for the group change to take effect.) The `_wsl` scripts start this daemon automatically (`systemctl start docker`) if it isn't already running, and fail with a clear, actionable error if Docker was never installed inside WSL at all.

Even though this is a completely separate engine from Docker Desktop's, **Docker Desktop's own dashboard can still be used to monitor and inspect whatever it builds or runs** — with WSL Integration enabled for Ubuntu (step 4 above), Docker Desktop's Containers and Images tabs surface containers regardless of which engine actually started them. You don't lose visibility by building through WSL instead of Docker Desktop.

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

...or skip this step entirely — `scripts\install_terraform.sh` handles it automatically (via a direct binary download rather than the apt route) every time either K3s script runs, and does nothing if Terraform is already installed.

Finally, install LocalStack and the AWS CLI — required, not optional, since MLflow and DVC both depend on a real S3 endpoint existing (see [The Automation Scripts](#the-automation-scripts) for exactly why skipping this makes training fail):

```bash
pip3 install localstack awscli
```

> Reference Python version: the API image and CI both pin **Python 3.9** — match it locally if you're running anything outside a container.

### Then: Pick a Path

**Docker Compose — fastest for local iteration:**

```bash
git clone https://github.com/benkeddad/mlops-demand-forecast.git
cd mlops-demand-forecast
scripts\deploy_compose_clean_wsl.bat        :: first run / full rebuild
scripts\deploy_compose_reconcile_wsl.bat    :: subsequent runs
```

Both run **as Administrator** (right-click → Run as administrator) — they need elevated rights to map WSL's ports back to Windows `localhost`. Once healthy: API docs at `http://localhost:8000/docs`, MLflow at `http://localhost:5000`, Prefect at `http://localhost:4200`, Postgres at `localhost:5432`.

**Terraform + K3s — production-shaped runtime:**

After the prerequisites above, with Docker Desktop running, right-click and **Run as Administrator**:

```bat
scripts\deploy_k3s_clean_wsl.bat        :: first deploy / clean slate
scripts\deploy_k3s_reconcile_wsl.bat    :: subsequent runs / recovery
```

Either script opens four live log/port-forward windows for the API, MLflow, Prefect, and Postgres when it finishes. Both scripts build images through WSL2's own Docker Engine; Docker Desktop only needs to be running so its dashboard can show you what's built/running — it doesn't do the building itself.

---

## API Surface

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Redirects to the Swagger UI (`/docs`) |
| `GET` | `/health` | Liveness + model-loaded status |
| `POST` | `/reload-model` | Forces an immediate reload of the latest registered MLflow model |
| `POST` | `/trigger-training` | Fires a real Prefect Deployment run of the training pipeline on demand (`run_deployment("Rossmann-Enterprise-Pipeline/production")`), same as an automatic `train_changed` DB notification would — also the hook the scheduled drift-monitoring workflow calls on detected drift |
| `GET` | `/predict/realtime/{store_id}` | Real-time single-store prediction via the Feast/Redis online store |

```bash
curl http://localhost:8000/health
curl http://localhost:8000/predict/realtime/1
curl -X POST http://localhost:8000/reload-model
curl -X POST http://localhost:8000/trigger-training
```

Batch prediction has no manually-called endpoint by design — it's triggered automatically by new rows in `test`, or immediately after a retraining cycle finishes.

---

## Configuration Reference

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | `postgresql://user:Password@postgres:5432/rossmann` | Postgres connection string (both the `asyncpg` and SQLAlchemy paths) |
| `MODEL_URI` | `models:/Rossmann_XGBoost_Model/latest` | MLflow Model Registry URI resolved at load/reload time |
| `MLFLOW_TRACKING_URI` | `http://mlflow:5000` | MLflow tracking + registry endpoint |
| `PREFECT_API_URL` | `http://prefect:4200/api` | Prefect server API endpoint — also what `run_deployment(...)` and `flow.serve()` use to find the server |
| `TRAINING_SCHEDULE_CRON` | *(unset)* | Optional cron expression (e.g. `"0 3 * * *"`) passed to `pipelines/serve_deployment.py`'s `flow.serve(cron=...)` — adds a periodic retraining schedule on top of the existing `train_changed` DB trigger. Unset by default, so nothing changes unless you opt in. |
| `WATCHFILES_FORCE_POLLING` | `true` | Forces filesystem-change polling for reliable hot-reload across the Docker Desktop/WSL2 volume boundary |

Postgres credentials are deliberately *not* in this table — Compose reads them from a gitignored `deploy/.env` (`deploy/.env.example` documents the shape) and Terraform reads them from `variable "postgres_user"` / `variable "postgres_password"` (override via `terraform.tfvars` or `TF_VAR_*`), both feeding into the connection strings above rather than being pasted into committed files directly.

---

## CI Pipeline

`.github/workflows/ci.yml`, on every push/PR to `main`:

1. Checks out the repo, sets up **Python 3.9**.
2. Installs `flake8`, `pytest`, and `requirements.txt`.
3. Lints with `flake8 --select=E9,F63,F7,F82` — fatal syntax errors and undefined names only, so the build fails fast on genuinely broken code rather than style nitpicks.
4. Runs `pytest -v` against the real suite in [`tests/`](tests/) — covering `src/evaluate.py`, `src/model.py`, `src/features.py`, `src/data.py`, `app/db_bootstrap.py`, and the Prefect task/flow wiring in `pipelines/` — and now actually fails the build on a real test failure instead of always passing.

A second workflow, `.github/workflows/drift-monitoring.yml`, runs on its own daily `schedule` (plus `workflow_dispatch` for on-demand runs): it seeds a throwaway Postgres service container, runs `monitoring/drift.py --fail-on-drift`, uploads the HTML report as a build artifact, and — if `RETRAIN_TRIGGER_URL` is configured as a repository variable — calls a deployed instance's `POST /trigger-training` when drift crosses the threshold.

---

## Known Limitations

Deliberate shortcuts, flagged explicitly rather than left for someone else to discover:

- Postgres credentials now live in a Kubernetes `Secret` (Terraform) and a gitignored `deploy/.env` (Compose) instead of being hardcoded in `main.tf`/`docker-compose.yaml` — but the *default* values in both are still the same well-known demo password (`user`/`Password`), and `feature_repo/feature_store.yaml`'s Feast config still hardcodes them directly. None of this comes from a real secrets manager (Vault, AWS Secrets Manager, etc.) — a real deployment must override `terraform.tfvars`/`deploy/.env` with its own values.
- The Kubernetes Ingress in front of the stack terminates TLS with a **self-signed certificate** generated by Terraform (`tls_self_signed_cert`) — fine for a demo, but browsers/clients will flag it, and there's still no authentication in front of the ingress or the `/trigger-training` endpoint. Every `Service` also remains `type: LoadBalancer` alongside the new Ingress, so the original direct-port access pattern (`localhost:8000`, etc.) keeps working unchanged.
- MLflow, Prefect, and Feast's registry each have their own Postgres database, but all four databases live on the **same single Postgres instance** — one outage takes down data, tracking, orchestration, and feature metadata together. MLflow's model artifacts now live in an S3-compatible bucket (LocalStack) instead of a PVC, but that bucket is itself one LocalStack container with persistence disabled — recreating it (or a host reboot that cycles the container) loses every artifact, and the `localstack_endpoint` Terraform variable is a hardcoded K3s node IP that silently goes stale if that address ever changes. Pre-migration model versions also remain reachable only through the old PVC path, not S3 — there was no retroactive artifact migration, only a cutover for new experiments (see [Hard-Won Lessons](#hard-won-lessons)).
- Training now runs as a real Prefect Deployment (`pipelines/serve_deployment.py`, triggered via `run_deployment(...)`) instead of an ad-hoc `subprocess` call, but the deployment server itself is still just a second subprocess launched by the API process (via `flow.serve()`), not a dedicated worker behind a work pool — it goes down with the API container and doesn't scale independently of it.
- `monitoring/drift.py`'s `--fail-on-drift` flag is now exercised by a real scheduled job (`.github/workflows/drift-monitoring.yml`), but that job runs against a throwaway, freshly-seeded Postgres container in CI, not the actual deployed stack — wiring its `RETRAIN_TRIGGER_URL` to a real, reachable, *authenticated* deployment is still left to whoever deploys this for real.
- The DVC S3 remote (`.dvc/config`) points at bucket name `rossmann-mlops-dvc-store`, which doesn't exist on real AWS. `scripts\setup_localstack_bucket.sh` (see [The Automation Scripts](#the-automation-scripts)) creates that same bucket inside **LocalStack** for local dev/testing; both the host shell (via a manually-run `dvc remote modify --local`) and every running container (via `docker/entrypoint.sh`, automatically, on every boot) layer the LocalStack endpoint/dummy credentials on top of the committed config the same way — through `.dvc/config.local`, never the committed `.dvc/config` itself. Pointing this at real AWS instead still requires `dvc remote modify storage url s3://<your-bucket>/dvc-store` plus real AWS credentials, and removing the LocalStack-only overrides in `config.local`.

---

## What's Next

Recently closed out (see [Known Limitations](#known-limitations) above for the honest caveats on each):

- [x] Real `pytest` coverage for `src/`, `app/`, and `pipelines/` — see [`tests/`](tests/), run via `pytest`
- [x] DVC remote storage on S3 instead of local disk — [`.dvc/config`](.dvc/config), `dvc[s3]` in `requirements.txt`
- [x] Kubernetes `Secret` + gitignored `deploy/.env` instead of plaintext Postgres credentials
- [x] A real scheduled/deployed Prefect flow run ([`pipelines/serve_deployment.py`](pipelines/serve_deployment.py) + `run_deployment(...)`) instead of the ad-hoc `subprocess` trigger
- [x] Ingress + TLS in front of the Kubernetes services (K3s' built-in Traefik + a self-signed cert)
- [x] `monitoring/drift.py` now runs on a schedule via [`.github/workflows/drift-monitoring.yml`](.github/workflows/drift-monitoring.yml)
- [x] MLflow model artifacts moved off the shared PVC and onto an S3-compatible bucket (LocalStack) — see [Infrastructure as Code](#infrastructure-as-code) and the caveats in [Known Limitations](#known-limitations)

Still open:

- [ ] Swap the self-signed ingress certificate for a CA-signed one (e.g. cert-manager + Let's Encrypt), and put real authentication in front of the ingress and `/trigger-training`
- [ ] Pull Postgres/Feast credentials from a real secrets manager (Vault, AWS Secrets Manager) instead of `terraform.tfvars` / `deploy/.env`
- [ ] Point `RETRAIN_TRIGGER_URL` at an actual reachable deployment, and track the scheduled drift job's own history over time instead of only its latest run
- [ ] Move the Prefect deployment server behind a real work pool + worker instead of a second subprocess living inside the API container
- [ ] Split Postgres, MLflow, and Feast onto separate instances (or at least separate volumes) so one outage doesn't take down every subsystem at once

---

## Author

Built by **Youcef Benkeddad** ([@benkeddad](https://github.com/benkeddad)) as an end-to-end demonstration of MLOps engineering — data versioning, feature stores, orchestration, experiment tracking, container orchestration, and infrastructure as code, wired into one working, closed-loop system.
