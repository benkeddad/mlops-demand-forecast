# Python 3.9 reached end-of-life in October 2025 - besides the security-patch
# exposure that comes with staying on it, it was also the direct cause of
# most of the warning noise this image used to print at boot:
#   - boto3 itself now warns on every run that Python 3.9 support is ending
#   - matplotlib (pulled in transitively by evidently) hasn't shipped a
#     Python 3.9 wheel since 3.9.4 (mid-2024), so pip was stuck resolving
#     that old release - which still calls pyparsing's now-deprecated
#     camelCase API (oneOf/parseString/resetCache/enablePackrat), firing a
#     PyparsingDeprecationWarning on every single matplotlib import. 3.12
#     resolves to current matplotlib (3.11.1+), which doesn't have this
#     problem. requirements.txt's psycopg2-binary pin was verified to still
#     ship a cp312 wheel, so this doesn't reopen that earlier issue.
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y git \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    # evidently<0.7.0 (see requirements.txt) unconditionally pulls in
    # litestar>=2.8.3 (its optional UI server dependency, unused by this
    # project - only Report/metric classes are imported in
    # monitoring/drift.py), which in turn unconditionally requires the
    # `multipart` PyPI package - a completely different, unrelated project
    # from `python-multipart` that happens to install a same-named
    # importable `multipart` module. Whichever of the two lands on disk
    # last silently overwrites the other's files, and if `multipart` wins,
    # FastAPI refuses to start any route using UploadFile/File with
    # "Form data requires python-multipart to be installed. It seems you
    # installed multipart instead." Force `python-multipart` to be the one
    # left on disk, regardless of resolver install order.
    && pip uninstall -y multipart \
    && pip install --no-cache-dir --force-reinstall --no-deps python-multipart

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

# Keep the entrypoint at the same path used by the repository layout.
# Kubernetes uses the copy stored in the image.
# Docker Compose provides the same path through the /app bind mount.

COPY docker/entrypoint.sh docker/entrypoint.sh
RUN chmod +x docker/entrypoint.sh

ENTRYPOINT ["./docker/entrypoint.sh"]
