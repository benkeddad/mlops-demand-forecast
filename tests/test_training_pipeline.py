from unittest.mock import patch

from pipelines.training_pipeline import (
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
    with patch("pipelines.training_pipeline.subprocess.run") as mock_run:
        dvc_ingest.fn()
    mock_run.assert_called_once()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "--force", "ingest"]
    assert kwargs["check"] is True


def test_featurize_stage_runs_plain_dvc_repro():
    with patch("pipelines.training_pipeline.subprocess.run") as mock_run:
        dvc_featurize.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "featurize"]
    assert kwargs["check"] is True


def test_train_stage_runs_plain_dvc_repro():
    with patch("pipelines.training_pipeline.subprocess.run") as mock_run:
        dvc_train.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "train"]
    assert kwargs["check"] is True


def test_push_stage_runs_dvc_push_when_s3_endpoint_configured():
    with patch.dict("os.environ", {"MLFLOW_S3_ENDPOINT_URL": "http://localstack:4566"}):
        with patch("pipelines.training_pipeline.subprocess.run") as mock_run:
            dvc_push.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "push"]
    assert kwargs["check"] is True


def test_push_stage_skips_dvc_push_without_s3_endpoint():
    with patch.dict("os.environ", {}, clear=True):
        with patch("pipelines.training_pipeline.subprocess.run") as mock_run:
            dvc_push.fn()
    mock_run.assert_not_called()
