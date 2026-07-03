FROM python:3.9-slim

WORKDIR /app

# Install git (required by DVC at runtime)
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Cache dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy pre-initialized DVC configurations and tracking files
COPY .dvc/ .dvc/
COPY dvc.yaml .
COPY dvc.lock .

# Copy your application modules
COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY data/raw/train.csv data/raw/train.csv
COPY monitoring/ monitoring/

# Start FastAPI and watch for CSV modifications inside data/raw
CMD ["sh", "-c", "mlflow server --host 127.0.0.1 --port 5000 & prefect server start --host 127.0.0.1 --port 4200 & sleep 15 && uvicorn app.main:app --host 0.0.0.0 --port 7860 --reload --reload-dir data/raw --reload-include *.csv"]
