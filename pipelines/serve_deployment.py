"""
Long-lived Prefect Deployment server for the training pipeline.

Replaces the old pattern of the API launching `pipelines/training_pipeline.py`
directly as an ad-hoc `subprocess.Popen` on every `train_changed` Postgres
notification. Instead, this script registers a single Prefect Deployment
("production") for `ml_training_pipeline` and then blocks forever, polling
the Prefect server for runs of that deployment - both scheduled ones (see
TRAINING_SCHEDULE_CRON below) and ones triggered on demand via
`prefect.deployments.run_deployment(...)`, which is what
`app/main.py::trigger_training_run()` calls now.

`flow.serve()` is Prefect 2.x's all-in-one deployment mechanism: it needs no
separate work pool or worker process, which keeps this to a single extra
long-running process (started once from app/main.py's lifespan) instead of a
whole extra service.

Run directly:
    python pipelines/serve_deployment.py
"""

import os

from training_pipeline import ml_training_pipeline

if __name__ == "__main__":
    # Unset by default so today's "only trains in response to a train_changed
    # DB notification" behavior is unchanged - set e.g. TRAINING_SCHEDULE_CRON
    # "0 3 * * *" to additionally retrain on a fixed schedule.
    cron_schedule = os.getenv("TRAINING_SCHEDULE_CRON") or None
    ml_training_pipeline.serve(name="production", cron=cron_schedule)
