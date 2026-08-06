# Hugging Face Space (Docker SDK) image: a single container running
# LocalStack (S3) + Postgres + Redis + MLflow + Prefect + FastAPI together
# (see docker/entrypoint.huggingface.sh) - HF Spaces expose exactly one port
# and give no docker-in-docker access, so the separate-container
# architecture used by deploy/docker-compose.yaml / deploy/terraform/main.tf
# doesn't apply here. Must be named exactly "Dockerfile" at the repo root -
# that's where HF Spaces looks for it, with no configurable path.
#
# Based on localstack/localstack:4.4.0 itself (same image k3s/Compose already
# pin) rather than a plain python image: its own entrypoint just execs
# `localstack-supervisor` directly from its bundled venv - no Docker socket,
# no account/license check at all (confirmed by reading that entrypoint
# script directly) - that requirement only exists in the much newer
# standalone `pip install localstack` CLI, a different tool. Debian 12
# bookworm underneath, same family as python:3.12-slim, with its own
# system-wide Python 3.11 free for this project's own dependencies.
FROM localstack/localstack:4.4.0

WORKDIR /app

# postgresql/redis-server: the in-container services this image bootstraps
# itself (see entrypoint). git: needed by pip for a couple of VCS deps.
# curl: used by health checks during boot.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl postgresql redis-server \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir -r requirements.txt

COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY monitoring/ monitoring/
COPY db/ db/
COPY dvc.yaml .
# Only the committed, shared remote pointer - see docker/api.Dockerfile's
# identical comment for why not the whole .dvc/ directory.
COPY .dvc/config .dvc/config
COPY .dvcignore .
COPY feature_repo/ feature_repo/
COPY data/ data/

COPY docker/entrypoint.huggingface.sh docker/entrypoint.huggingface.sh
RUN chmod +x docker/entrypoint.huggingface.sh

# Matches this file's app_port in the README.md Space metadata.
ENV APP_PORT=7860
EXPOSE 7860 4566

ENTRYPOINT ["./docker/entrypoint.huggingface.sh"]
