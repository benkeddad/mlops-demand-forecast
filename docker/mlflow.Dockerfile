# CHANGED: Create custom image to install psycopg2-binary driver on top of official MLflow base
FROM ghcr.io/mlflow/mlflow:latest
# boto3 pinned to match requirements.txt's dvc-s3/aiobotocore-compatible chain
# (boto3==1.41.5 needs botocore==1.41.5, which is exactly what aiobotocore
# pins) - needed for MLflow's S3 artifact repository (--default-artifact-root
# s3://...) to actually work.
RUN pip install --no-cache-dir psycopg2-binary boto3==1.41.5
# END OF CHANGE