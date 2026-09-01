from unittest.mock import patch

# Bare import (`optimal_training_pipeline`, not `pipelines.optimal_training_pipeline`)
# for the same reason test_training_pipeline.py imports `training_pipeline`
# bare - see that file's comment. This module's own `from training_pipeline
# import _run_dvc, dvc_ingest, dvc_push` is bare too, so it resolves to the
# same already-loaded `training_pipeline` module either way.
from optimal_training_pipeline import dvc_featurize_rich, dvc_train_optimal, ml_optimal_training_pipeline


def test_optimal_pipeline_flow_is_named_for_the_prefect_ui():
    assert ml_optimal_training_pipeline.name == "Rossmann-Optimal-Training-Pipeline"


def test_optimal_pipeline_reuses_the_fast_pipelines_ingest_and_push_tasks():
    # dvc_featurize_rich and dvc_train_optimal are new tasks specific to this
    # flow - ingest/push are the exact same Prefect task objects imported
    # from training_pipeline.py, not reimplemented copies.
    import training_pipeline
    assert ml_optimal_training_pipeline.fn.__globals__["dvc_ingest"] is training_pipeline.dvc_ingest
    assert ml_optimal_training_pipeline.fn.__globals__["dvc_push"] is training_pipeline.dvc_push


def test_optimal_pipeline_does_not_reuse_the_lean_featurize_task():
    # train_optimal.py trains on build_features_rich()'s output, not the
    # lean train_features.parquet dvc_featurize() (training_pipeline.py)
    # produces - this flow must run its own featurize_rich task instead.
    import training_pipeline
    assert "dvc_featurize" not in ml_optimal_training_pipeline.fn.__globals__
    assert ml_optimal_training_pipeline.fn.__globals__["dvc_featurize_rich"] is dvc_featurize_rich
    assert dvc_featurize_rich is not training_pipeline.dvc_featurize


def test_featurize_rich_stage_runs_plain_dvc_repro():
    with patch("training_pipeline.subprocess.run") as mock_run:
        dvc_featurize_rich.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "featurize_rich"]
    assert kwargs["check"] is True


def test_train_optimal_stage_runs_plain_dvc_repro():
    with patch("training_pipeline.subprocess.run") as mock_run:
        dvc_train_optimal.fn()
    args, kwargs = mock_run.call_args
    assert args[0] == ["dvc", "repro", "train_optimal"]
    assert kwargs["check"] is True
