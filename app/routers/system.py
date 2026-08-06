"""System-level observability: liveness/readiness probes + Prometheus
metrics. Split from /health (kept as-is for backwards compatibility) so
Kubernetes-style probes have a real distinction: /live only checks the
process itself is up, /ready also checks the model is loaded and Postgres
is actually reachable.
"""
import asyncpg
from fastapi import APIRouter, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

from app import state

router = APIRouter(tags=["system"])

REQUEST_COUNT = Counter(
    "api_requests_total", "Total HTTP requests handled", ["method", "path", "status_code"]
)
REQUEST_LATENCY = Histogram(
    "api_request_latency_seconds", "Request latency in seconds", ["method", "path"]
)
MODEL_LOADED_GAUGE = Gauge(
    "model_loaded", "1 if the serving model is currently loaded in memory, else 0"
)


@router.get("/live", summary="Liveness probe - the process itself is up")
def liveness():
    return {"status": "alive"}


@router.get("/ready", summary="Readiness probe - model loaded and Postgres reachable")
async def readiness(response: Response):
    model_ok = state.get_model() is not None
    db_ok = True
    db_error = None
    try:
        conn = await asyncpg.connect(state.DB_URL, timeout=3)
        await conn.close()
    except Exception as exc:
        db_ok = False
        db_error = str(exc)

    if not (model_ok and db_ok):
        response.status_code = 503
    body = {"model_loaded": model_ok, "model_uri": state.get_model_uri(), "database_reachable": db_ok}
    if db_error:
        body["database_error"] = db_error
    return body


@router.get("/metrics", summary="Prometheus-format metrics")
def metrics():
    MODEL_LOADED_GAUGE.set(1 if state.get_model() is not None else 0)
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
