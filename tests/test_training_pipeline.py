from unittest.mock import patch

# Imported script-style (`training_pipeline`, not `pipelines.training_pipeline`)
# to match how pipelines/serve_deployment.py imports this same module in
# production (`from training_pipeline import ml_training_pipeline`, resolved
# via pytest.ini's `pythonpath = . src pipelines`). Importing it under a
# second, package-qualified name here would load the module a second time
# under a different identity, and Prefect's in-process task/flow registry
# would then see every @task/@flow in this file defined twice - real
# duplicate registrations, not just a cosmetic warning - only because the
# test suite exercises both import styles in the same interpreter (something
# that never happens in production, where each entrypoint only ever imports
# this module one way).
from training_pipeline import (
    dvc_featurize,
    dvc_ingest,
    dvc_push,
    dvc_train,
    ml_training_pipeline,
)


def test_pipeline_flow_is_named_for_the_prefect_ui():
    assert ml_training_pipeline.name == "Rossmann-Enterprise-Pipeline"


def test_ingest_stage_forces_dvc_repro():
    # --force bypasses DVC's cache check, because the real change happened
    # inside Postgres, which DVC has no visibility into.
    with patch("training_pipeline.subprocess.run") as mock_run:
        dvc_ingest.fn()
    mock_run.assert_called_once()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "--force", "ingest"]
    assert kwargs["check"] is True


def test_featurize_stage_runs_plain_dvc_repro():
    with patch("training_pipeline.subprocess.run") as mock_run:
        dvc_featurize.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "featurize"]
    assert kwargs["check"] is True


def test_train_stage_runs_plain_dvc_repro():
    with patch("training_pipeline.subprocess.run") as mock_run:
        dvc_train.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "train"]
    assert kwargs["check"] is True


def test_push_stage_runs_dvc_push_when_s3_endpoint_configured():
    with patch.dict("os.environ", {"MLFLOW_S3_ENDPOINT_URL": "http://localstack:4566"}):
        with patch("training_pipeline.subprocess.run") as mock_run:
            dvc_push.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "push"]
    assert kwargs["check"] is True


def test_ingest_stage_passes_localstack_endpoint_to_dvc_subprocess():
    with patch.dict("os.environ", {"MLFLOW_S3_ENDPOINT_URL": "http://localstack:4566"}, clear=True):
        with patch("training_pipeline.subprocess.run") as mock_run:
            dvc_ingest.fn()
    _, kwargs = mock_run.call_args
    assert kwargs["env"]["AWS_ENDPOINT_URL"] == "http://localstack:4566"
    assert kwargs["env"]["AWS_ENDPOINT_URL_S3"] == "http://localstack:4566"


def test_push_stage_skips_dvc_push_without_s3_endpoint():
    with patch.dict("os.environ", {}, clear=True):
        with patch("training_pipeline.subprocess.run") as mock_run:
            dvc_push.fn()
    mock_run.assert_not_called()
