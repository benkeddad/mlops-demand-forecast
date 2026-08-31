"""Model reproducibility auditing, exposed over this API for the same reason
as the other routers - no other reachable UI/CLI access in a
single-container deployment.

Ported from the standalone rossmann-forecasting-automated-model-training
project's api/reproducibility_api.py (a separate FastAPI app on its own
port) into this app's router pattern. Runs pipelines/reproduction_pipeline.py
as a subprocess in a background task - the same cross-process pattern
app/main.py already uses for pipelines/serve_deployment.py - rather than
importing and calling the Prefect flow in-process, since the flow shells out
to `dvc` itself either way and a subprocess boundary keeps a slow/failed
reproduction run from ever affecting this API process's own event loop.
"""
import json
import logging
import os
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel

from app.auth import require_api_key

logger = logging.getLogger("sales_api")

router = APIRouter(prefix="/reproducibility", tags=["reproducibility"])

PROJECT_ROOT = Path(__file__).resolve().parents[2]
JOB_DIR = Path(os.getenv("REPRO_JOB_DIR", PROJECT_ROOT / "reproduction_jobs"))
JOB_DIR.mkdir(parents=True, exist_ok=True)


class JobResponse(BaseModel):
    job_id: str
    run_id: str
    status: str


def _job_path(job_id: str) -> Path:
    return JOB_DIR / f"{job_id}.json"


def _write_job(job_id: str, payload: dict):
    _job_path(job_id).write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _run_job(job_id: str, run_id: str, execute_retrain: bool, tolerance: float):
    payload = {"job_id": job_id, "run_id": run_id, "status": "running", "execute_retrain": execute_retrain}
    _write_job(job_id, payload)
    cmd = [sys.executable, "pipelines/reproduction_pipeline.py", run_id]
    if execute_retrain:
        cmd.append("--execute-retrain")
    cmd += ["--tolerance", str(tolerance)]
    proc = subprocess.run(cmd, cwd=PROJECT_ROOT, text=True, capture_output=True, env=os.environ.copy())
    payload.update({
        "status": "completed" if proc.returncode == 0 else "failed",
        "returncode": proc.returncode,
        "stdout_tail": proc.stdout[-4000:],
        "stderr_tail": proc.stderr[-4000:],
    })
    _write_job(job_id, payload)
    if proc.returncode != 0:
        logger.error(f"Reproducibility job {job_id} (run_id={run_id}) failed: {proc.stderr[-2000:]}")


@router.post(
    "/{run_id}",
    response_model=JobResponse,
    summary="Start a reproducibility audit for a past MLflow run - control action",
    dependencies=[Depends(require_api_key)],
)
async def start_reproducibility_job(
    run_id: str,
    background_tasks: BackgroundTasks,
    execute_retrain: bool = False,
    tolerance: float = 1e-3,
):
    """Retrieves the run's logged metadata/artifacts and checks whether the
    current training data still hashes the same as what produced it.
    execute_retrain=true goes further: actually re-runs `dvc repro train`
    and diffs the resulting metrics against the original within `tolerance`
    - the expensive path, gated behind API key like this project's other
    control actions (/trigger-training, /data/upload/*)."""
    job_id = f"repro-{uuid4().hex[:12]}"
    _write_job(job_id, {"job_id": job_id, "run_id": run_id, "status": "queued", "execute_retrain": execute_retrain})
    background_tasks.add_task(_run_job, job_id, run_id, execute_retrain, tolerance)
    return JobResponse(job_id=job_id, run_id=run_id, status="queued")


@router.get("/jobs/{job_id}", summary="Check the status/result of a reproducibility audit job")
async def get_job(job_id: str):
    path = _job_path(job_id)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Job not found")
    return json.loads(path.read_text(encoding="utf-8"))
