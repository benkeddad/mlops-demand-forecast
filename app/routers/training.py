"""Prefect training-run observability + control, exposed over this API for
the same reason as app/routers/models.py - no other reachable UI in a
single-container deployment.
"""
from fastapi import APIRouter, Depends, HTTPException
from prefect.client.orchestration import get_client
from prefect.client.schemas.filters import FlowRunFilter, FlowRunFilterId
from prefect.client.schemas.sorting import FlowRunSort
from prefect.states import Cancelled

from app.auth import require_api_key

router = APIRouter(prefix="/training", tags=["training"])


def _serialize_flow_run(r) -> dict:
    return {
        "id": str(r.id),
        "name": r.name,
        "state": r.state.type.value if r.state else None,
        "state_name": r.state.name if r.state else None,
        "start_time": r.start_time.isoformat() if r.start_time else None,
        "end_time": r.end_time.isoformat() if r.end_time else None,
    }


@router.get("/runs", summary="List recent training pipeline runs")
async def list_flow_runs(limit: int = 20):
    async with get_client() as client:
        runs = await client.read_flow_runs(sort=FlowRunSort.START_TIME_DESC, limit=limit)
    return [_serialize_flow_run(r) for r in runs]


@router.get("/runs/{flow_run_id}", summary="Detail for a single training run, including its tasks")
async def flow_run_detail(flow_run_id: str):
    async with get_client() as client:
        try:
            run = await client.read_flow_run(flow_run_id)
        except Exception:
            raise HTTPException(status_code=404, detail=f"Flow run '{flow_run_id}' not found.")
        task_runs = await client.read_task_runs(
            flow_run_filter=FlowRunFilter(id=FlowRunFilterId(any_=[flow_run_id]))
        )
    detail = _serialize_flow_run(run)
    detail["tasks"] = [
        {
            "id": str(t.id),
            "name": t.name,
            "state": t.state.type.value if t.state else None,
            "start_time": t.start_time.isoformat() if t.start_time else None,
            "end_time": t.end_time.isoformat() if t.end_time else None,
        }
        for t in task_runs
    ]
    return detail


@router.post(
    "/runs/{flow_run_id}/cancel",
    summary="Cancel an in-progress training run - control action",
    dependencies=[Depends(require_api_key)],
)
async def cancel_flow_run(flow_run_id: str):
    async with get_client() as client:
        try:
            await client.set_flow_run_state(
                flow_run_id, state=Cancelled(message="Cancelled via API"), force=True
            )
        except Exception as exc:
            raise HTTPException(status_code=400, detail=f"Could not cancel run: {exc}")
    return {"status": "cancelled", "flow_run_id": flow_run_id}
