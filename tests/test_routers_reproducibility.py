import json
from unittest.mock import MagicMock, patch

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routers import reproducibility as repro_router

app = FastAPI()
app.include_router(repro_router.router)
client = TestClient(app)


@pytest.fixture(autouse=True)
def _job_dir(tmp_path, monkeypatch):
    """Redirect JOB_DIR to a throwaway directory for every test in this
    file, instead of the real project's reproduction_jobs/."""
    monkeypatch.setattr(repro_router, "JOB_DIR", tmp_path)
    return tmp_path


def _fake_completed_process(returncode=0, stdout="ok", stderr=""):
    proc = MagicMock()
    proc.returncode = returncode
    proc.stdout = stdout
    proc.stderr = stderr
    return proc


def test_start_job_returns_queued_then_completed_after_background_task():
    with patch("app.routers.reproducibility.subprocess.run", return_value=_fake_completed_process()) as run_mock:
        resp = client.post("/reproducibility/abc123")

    assert resp.status_code == 200
    body = resp.json()
    assert body["run_id"] == "abc123"
    assert body["job_id"].startswith("repro-")
    # TestClient runs BackgroundTasks synchronously before returning, so by
    # now the job file should already reflect the subprocess's outcome.
    job_file = _job_dir_file(body["job_id"])
    saved = json.loads(job_file.read_text())
    assert saved["status"] == "completed"
    assert saved["returncode"] == 0
    run_mock.assert_called_once()
    cmd = run_mock.call_args.args[0]
    assert cmd[1:3] == ["pipelines/reproduction_pipeline.py", "abc123"]
    assert "--execute-retrain" not in cmd


def test_start_job_passes_execute_retrain_and_tolerance_through():
    with patch("app.routers.reproducibility.subprocess.run", return_value=_fake_completed_process()) as run_mock:
        resp = client.post("/reproducibility/abc123", params={"execute_retrain": True, "tolerance": 0.01})

    assert resp.status_code == 200
    cmd = run_mock.call_args.args[0]
    assert "--execute-retrain" in cmd
    assert "0.01" in cmd


def test_start_job_marks_failed_on_nonzero_returncode():
    with patch("app.routers.reproducibility.subprocess.run", return_value=_fake_completed_process(returncode=1, stderr="boom")):
        resp = client.post("/reproducibility/abc123")

    job_id = resp.json()["job_id"]
    saved = json.loads(_job_dir_file(job_id).read_text())
    assert saved["status"] == "failed"
    assert saved["returncode"] == 1
    assert "boom" in saved["stderr_tail"]


def test_get_job_404_when_missing():
    resp = client.get("/reproducibility/jobs/does-not-exist")
    assert resp.status_code == 404


def test_get_job_returns_saved_payload():
    with patch("app.routers.reproducibility.subprocess.run", return_value=_fake_completed_process()):
        start = client.post("/reproducibility/abc123")
    job_id = start.json()["job_id"]

    resp = client.get(f"/reproducibility/jobs/{job_id}")
    assert resp.status_code == 200
    assert resp.json()["run_id"] == "abc123"


def test_start_job_requires_api_key_when_set():
    with patch("app.auth.API_KEY", "secret"):
        resp = client.post("/reproducibility/abc123")
    assert resp.status_code == 401


def _job_dir_file(job_id):
    # Mirrors repro_router._job_path() against the currently-patched JOB_DIR.
    return repro_router.JOB_DIR / f"{job_id}.json"
