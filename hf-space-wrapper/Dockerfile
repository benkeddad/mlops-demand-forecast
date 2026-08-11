FROM localstack/localstack:4.4.0

WORKDIR /workspace

ARG SOURCE_REPO_URL=https://github.com/benkeddad/mlops-demand-forecast.git
ARG SOURCE_COMMIT=5e8a709402beafd1238881c581f441a3171a3216

RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl postgresql redis-server \
    && rm -rf /var/lib/apt/lists/*

# Clone an immutable revision so every build runs the exact same code.
RUN git init /app \
    && cd /app \
    && git remote add origin ${SOURCE_REPO_URL} \
    && git fetch --depth 1 origin ${SOURCE_COMMIT} \
    && git checkout --detach FETCH_HEAD

WORKDIR /app

RUN pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir -r requirements.txt \
    # See docker/api.Dockerfile for why: evidently<0.7.0 -> litestar -> the
    # unrelated `multipart` package clobbers python-multipart's same-named
    # module on disk, breaking any UploadFile/File route unless forced back.
    && pip3 uninstall -y multipart \
    && pip3 install --no-cache-dir --force-reinstall --no-deps python-multipart

RUN chmod +x docker/entrypoint.huggingface.sh

ENV APP_PORT=7860
EXPOSE 7860

ENTRYPOINT ["./docker/entrypoint.huggingface.sh"]
