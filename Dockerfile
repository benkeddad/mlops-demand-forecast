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

# Copy your application modules
COPY app/ app/
COPY pipelines/ pipelines/
COPY src/ src/
COPY data/ data/
COPY monitoring/ monitoring/

# Start FastAPI directly without shell scripts
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]