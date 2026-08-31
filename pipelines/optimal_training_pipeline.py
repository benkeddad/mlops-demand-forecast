"""Prefect flow for the expensive RFECV+Optuna training path
(src/train_optimal.py via the DVC "train_optimal" stage). Mirrors
pipelines/training_pipeline.py's ingest -> featurize -> train -> push
structure exactly, swapping only the training stage - ingest/featurize are
still re-run first (DVC's own cache makes a no-op skip cheap if the
underlying data hasn't changed, and this guarantees correctness if it has).

Registered as its own Prefect deployment - see pipelines/serve_deployment.py
- and triggered on demand via POST /trigger-optimal-training
(app/main.py), never on the automatic train_changed path the fast
pipeline (training_pipeline.py) runs on.
"""
import warnings

from pydantic import PydanticDeprecatedSince20

# Same reasoning as pipelines/training_pipeline.py's identical filter -
# fires the instant `prefect` is imported, entirely inside Prefect's source.
warnings.filterwarnings(
    "ignore",
    message=r"Support for class-based `config` is deprecated.*",
    category=PydanticDeprecatedSince20,
)
from prefect import flow, task  # noqa: E402

from training_pipeline import _run_dvc, dvc_ingest, dvc_featurize, dvc_push  # noqa: E402


@task(name="3. DVC: Optimal Model Training (RFECV + Optuna)")
def dvc_train_optimal():
    print("Triggering DVC Optimal Training Stage (RFECV + Optuna)...")
    _run_dvc(["dvc", "repro", "train_optimal"])


@flow(name="Rossmann-Optimal-Training-Pipeline")
def ml_optimal_training_pipeline():
    # Same three DVC tasks training_pipeline.py reuses (dvc_ingest,
    # dvc_featurize, dvc_push) - only the training task itself differs.
    dvc_ingest()
    dvc_featurize()
    dvc_train_optimal()
    dvc_push()


if __name__ == "__main__":
    ml_optimal_training_pipeline()
    print("Optimal training pipeline script finished")
