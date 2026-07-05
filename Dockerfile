FROM python:3.9-slim

WORKDIR /app

# Install git (required by DVC at runtime)
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Cache dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy your application modules FIRST
COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY data/raw/train.csv data/raw/train.csv
COPY monitoring/ monitoring/

# Initialize DVC NOW so it encapsulates project structure safely
RUN dvc init --no-scm --force

# Start FastAPI and watch for CSV modifications inside data/raw
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload", "--reload-dir", "data/raw", "--reload-include", "*.csv"]
