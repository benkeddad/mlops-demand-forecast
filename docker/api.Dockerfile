FROM python:3.9-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y git \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Copy application files into the image.
COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY monitoring/ monitoring/
COPY dvc.yaml .
# Only the committed, shared remote pointer - NOT .dvc/config.local (dev-
# machine-only LocalStack endpoint/creds, meaningless inside a container's
# own network namespace anyway - 127.0.0.1 there means the container itself,
# not the WSL host LocalStack listens on) or .dvc/tmp/ (DVC's own runtime
# scratch dir).
COPY .dvc/config .dvc/config
COPY .dvcignore .
COPY feature_repo/ feature_repo/
COPY data/ data/

# Keep the entrypoint at the same path used by the repository layout.
# Kubernetes uses the copy stored in the image.
# Docker Compose provides the same path through the /app bind mount.

COPY docker/entrypoint.sh docker/entrypoint.sh
RUN chmod +x docker/entrypoint.sh

ENTRYPOINT ["./docker/entrypoint.sh"]
