FROM python:3.9-slim

WORKDIR /app

# Install git (required by DVC at runtime)
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Cache dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy your application modules
COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY monitoring/ monitoring/
COPY dvc.yaml .

# Copy your Feast repository configurations so the API can talk to Redis
COPY feature_repo/ feature_repo/

# Initialize DVC safely
RUN dvc init --no-scm --force

# Start FastAPI normally without the obsolete CSV file-watching parameters
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]