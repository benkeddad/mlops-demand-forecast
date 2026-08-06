"""MLflow model-registry observability + control, exposed over this API
since a Hugging Face Space (or any deployment where only this API's port is
reachable) gives no other way to browse the MLflow UI directly.
"""
from fastapi import APIRouter, Depends, HTTPException
from mlflow.tracking import MlflowClient

from app import state
from app.auth import require_api_key

router = APIRouter(prefix="/models", tags=["models"])


def _client() -> MlflowClient:
    return MlflowClient(tracking_uri=state.MLFLOW_URI)


@router.get("", summary="List all registered models")
def list_models():
    return [
        {"name": m.name, "latest_versions": [v.version for v in m.latest_versions]}
        for m in _client().search_registered_models()
    ]


@router.get("/current", summary="Metadata for the model currently loaded in this process")
def current_model():
    model = state.get_model()
    if model is None:
        raise HTTPException(status_code=503, detail="No model is currently loaded.")
    meta = model.metadata
    return {
        "model_uri": state.get_model_uri(),
        "run_id": meta.run_id,
        "model_uuid": getattr(meta, "model_uuid", None),
        "flavors": list(meta.flavors.keys()),
        "signature": meta.signature.to_dict() if meta.signature else None,
    }


@router.get("/{name}/versions", summary="List all versions of a registered model")
def list_versions(name: str):
    versions = _client().search_model_versions(f"name='{name}'")
    if not versions:
        raise HTTPException(status_code=404, detail=f"No versions found for model '{name}'.")
    return [
        {
            "version": v.version,
            "run_id": v.run_id,
            "status": v.status,
            "aliases": list(v.aliases) if v.aliases else [],
            "creation_timestamp": v.creation_timestamp,
        }
        for v in sorted(versions, key=lambda v: int(v.version), reverse=True)
    ]


@router.post(
    "/{name}/versions/{version}/promote",
    summary="Alias a model version (e.g. 'production') - control action",
    dependencies=[Depends(require_api_key)],
)
def promote_version(name: str, version: str, alias: str = "production"):
    try:
        _client().set_registered_model_alias(name, alias, version)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not set alias: {exc}")
    return {"status": "promoted", "name": name, "version": version, "alias": alias}


@router.post(
    "/rollback/{version}",
    summary="Reload the running API's serving model to a specific version - control action",
    dependencies=[Depends(require_api_key)],
)
def rollback(version: str):
    target_uri = f"models:/{state.REGISTERED_MODEL_NAME}/{version}"
    if not state.load_model(target_uri):
        raise HTTPException(status_code=400, detail=f"Could not load {target_uri}.")
    return {"status": "rolled back", "model_uri": target_uri}


@router.get("/experiments", summary="List MLflow experiments")
def list_experiments():
    return [
        {"experiment_id": e.experiment_id, "name": e.name, "lifecycle_stage": e.lifecycle_stage}
        for e in _client().search_experiments()
    ]


@router.get("/experiments/{experiment_id}/runs", summary="List runs in an experiment")
def list_runs(experiment_id: str, max_results: int = 20):
    runs = _client().search_runs(
        [experiment_id], max_results=max_results, order_by=["start_time DESC"]
    )
    return [
        {
            "run_id": r.info.run_id,
            "status": r.info.status,
            "start_time": r.info.start_time,
            "end_time": r.info.end_time,
            "metrics": r.data.metrics,
            "params": r.data.params,
        }
        for r in runs
    ]


@router.get("/runs/{run_id}", summary="Full detail for a single MLflow run")
def run_detail(run_id: str):
    try:
        r = _client().get_run(run_id)
    except Exception:
        raise HTTPException(status_code=404, detail=f"Run '{run_id}' not found.")
    return {
        "run_id": r.info.run_id,
        "status": r.info.status,
        "start_time": r.info.start_time,
        "end_time": r.info.end_time,
        "metrics": r.data.metrics,
        "params": r.data.params,
        "tags": r.data.tags,
        "artifact_uri": r.info.artifact_uri,
    }
