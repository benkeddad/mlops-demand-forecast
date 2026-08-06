"""API-key gate for control/write endpoints (trigger training, reload model,
promote/rollback a model version, cancel a training run, etc.).

Deliberately optional: if API_KEY isn't set (e.g. local dev, or a private
network deployment) every request is allowed through unchanged - today's
behavior. Set the API_KEY environment variable to actually require callers
to send a matching X-API-Key header. Read-only observability endpoints are
NOT gated - this project's dashboard/API is meant to be the only interface
available (e.g. on a Hugging Face Space, where Postgres/MLflow/Prefect have
no other reachable UI), so browsing state should stay open by default.
"""
import os
from fastapi import Header, HTTPException

API_KEY = os.getenv("API_KEY")


def require_api_key(x_api_key: str = Header(default=None)):
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Missing or invalid X-API-Key header")
