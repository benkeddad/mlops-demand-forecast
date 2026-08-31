"""
Long-lived Prefect Deployment server for both training pipelines.

Replaces the old pattern of the API launching `pipelines/training_pipeline.py`
directly as an ad-hoc `subprocess.Popen` on every `train_changed` Postgres
notification. Instead, this script registers two Prefect Deployments -
"production" for the fast fixed-hyperparameter `ml_training_pipeline`, and
"production" for the expensive RFECV+Optuna `ml_optimal_training_pipeline`
(pipelines/optimal_training_pipeline.py) - and then blocks forever, serving
both concurrently in a single process. Prefect's `serve(*deployments)` is
what enables that: unlike the single-flow `flow.serve(name=...)` form this
file used before there were two flows to run, `serve()` takes any number of
pre-built deployments (via `flow.to_deployment(name=...)`) and polls for
runs of all of them in one long-lived process - still just the one extra
process started from app/main.py's lifespan, not two.

`app/main.py`'s `run_deployment("Rossmann-Enterprise-Pipeline/production")`
and `run_deployment("Rossmann-Optimal-Training-Pipeline/production")` (the
`/trigger-training` and `/trigger-optimal-training` endpoints) both talk to
whichever of these two deployments they name - the process serving them
doesn't distinguish between "on demand" and "on a train_changed
notification"; both training pipelines are always triggered the same way.

Run directly:
    python pipelines/serve_deployment.py
"""

import os

from prefect import serve

from training_pipeline import ml_training_pipeline
from optimal_training_pipeline import ml_optimal_training_pipeline

if __name__ == "__main__":
    # Unset by default so today's "only trains in response to a train_changed
    # DB notification" behavior is unchanged - set e.g. TRAINING_SCHEDULE_CRON
    # "0 3 * * *" to additionally retrain (the fast path) on a fixed schedule.
    # The optimal path has no schedule of its own - it's deliberately manual
    # (POST /trigger-optimal-training) only, never automatic.
    cron_schedule = os.getenv("TRAINING_SCHEDULE_CRON") or None
    fast_deployment = ml_training_pipeline.to_deployment(name="production", cron=cron_schedule)
    optimal_deployment = ml_optimal_training_pipeline.to_deployment(name="production")
    serve(fast_deployment, optimal_deployment)
