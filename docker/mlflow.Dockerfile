# CHANGED: Create custom image to install psycopg2-binary driver on top of official MLflow base
FROM ghcr.io/mlflow/mlflow:latest
RUN pip install --no-cache-dir psycopg2-binary
# END OF CHANGE