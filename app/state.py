"""
Shared mutable app state (currently-loaded model) - split out of app/main.py
so the new observability/control routers (app/routers/*) can read/reload the
model without importing app.main itself (which would create a circular
import, since main.py is what wires those routers in).
"""
import os
import logging

import mlflow
import mlflow.pyfunc

logger = logging.getLogger("sales_api")

MLFLOW_URI = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
REGISTERED_MODEL_NAME = "Rossmann_XGBoost_Model"
DEFAULT_MODEL_URI = os.getenv("MODEL_URI", f"models:/{REGISTERED_MODEL_NAME}/latest")
DB_URL = os.getenv("DATABASE_URL", "postgresql://user:Password@localhost:5432/rossmann")

mlflow.set_tracking_uri(MLFLOW_URI)
mlflow.set_registry_uri(MLFLOW_URI)

_model = None
_model_uri = DEFAULT_MODEL_URI


def get_model():
    return _model


def get_model_uri() -> str:
    return _model_uri


def load_model(uri: str = None) -> bool:
    """(Re)loads the serving model. Defaults to DEFAULT_MODEL_URI (today's
    behavior) - pass an explicit uri (e.g. models:/Name/7) to roll back/
    forward to a specific registered version."""
    global _model, _model_uri
    target = uri or DEFAULT_MODEL_URI
    try:
        _model = mlflow.pyfunc.load_model(target)
        _model_uri = target
        logger.info(f"Model loaded successfully from {target}.")
        return True
    except Exception as e:
        logger.error(f"Load failed ({target}): {e}")
        return False
