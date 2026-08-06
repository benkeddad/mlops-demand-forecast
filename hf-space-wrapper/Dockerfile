FROM localstack/localstack:4.4.0

WORKDIR /workspace

ARG SOURCE_REPO_URL=https://github.com/benkeddad/mlops-demand-forecast.git
ARG SOURCE_REF=main

RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl postgresql redis-server \
    && rm -rf /var/lib/apt/lists/*

# Clone only the latest snapshot to keep build time and image size lower.
RUN git clone --depth 1 --branch ${SOURCE_REF} ${SOURCE_REPO_URL} /app

WORKDIR /app

RUN pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir -r requirements.txt

RUN chmod +x docker/entrypoint.huggingface.sh

ENV APP_PORT=7860
EXPOSE 7860

ENTRYPOINT ["./docker/entrypoint.huggingface.sh"]
