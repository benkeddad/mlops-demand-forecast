import pipelines.serve_deployment as serve_deployment


def test_serve_deployment_exposes_the_training_flow():
    # Confirms the module wiring (bare `from training_pipeline import
    # ml_training_pipeline`, resolved via pipelines/ being on sys.path when
    # this script is run directly) without invoking the blocking .serve()
    # call itself, which only runs under `if __name__ == "__main__":`.
    assert serve_deployment.ml_training_pipeline.name == "Rossmann-Enterprise-Pipeline"


def test_serve_deployment_exposes_the_optimal_training_flow():
    # Same wiring check for the second flow this module now serves
    # concurrently (see pipelines/optimal_training_pipeline.py) - added
    # alongside the fast pipeline above, which is unchanged.
    assert serve_deployment.ml_optimal_training_pipeline.name == "Rossmann-Optimal-Training-Pipeline"
