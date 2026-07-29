import pipelines.serve_deployment as serve_deployment


def test_serve_deployment_exposes_the_training_flow():
    # Confirms the module wiring (bare `from training_pipeline import
    # ml_training_pipeline`, resolved via pipelines/ being on sys.path when
    # this script is run directly) without invoking the blocking .serve()
    # call itself, which only runs under `if __name__ == "__main__":`.
    assert serve_deployment.ml_training_pipeline.name == "Rossmann-Enterprise-Pipeline"
