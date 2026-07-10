FROM python:3.9-slim

WORKDIR /app

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# We still copy files here so the image has them even if you don't use volume mounts later
COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY monitoring/ monitoring/
COPY dvc.yaml .
COPY feature_repo/ feature_repo/
COPY data/ data/

# Copy the entrypoint script and grant execution permissions
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Removed the RUN dvc init from here!

ENTRYPOINT ["./entrypoint.sh"]