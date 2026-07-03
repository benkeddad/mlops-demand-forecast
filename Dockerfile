FROM python:3.9-slim

# 1. Install system utilities (git is required to pull the branch and run DVC)
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# 2. Setup the mandatory Hugging Face non-root user (UID 1000)
RUN useradd -m -u 1000 user
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH
WORKDIR $HOME/app

# 3. Ensure the non-root user owns the workspace directory
RUN chown -R user:user $HOME

# Switch to the non-root user for cloning and execution
USER user

# 4. Clone your specific target branch directly from GitHub into the container
RUN git clone -b main_for_hugging_face_server https://github.com/benkeddad/mlops-demand-forecast.git .

# 5. Install the Python dependencies directly from your branch's requirements file
RUN pip install --no-cache-dir -r requirements.txt

# 6. Set environment variables to route traffic to the headless background engines
ENV MLFLOW_TRACKING_URI=http://127.0.0.1:5000
ENV PREFECT_API_URL=http://127.0.0.1:4200/api

# 7. Expose the mandatory Hugging Face traffic port
EXPOSE 7860

# 8. Start MLflow and Prefect in the background, then launch your FastAPI application
CMD ["sh", "-c", "mlflow server --host 127.0.0.1 --port 5000 & prefect server start --host 127.0.0.1 --port 4200 & uvicorn app.main:app --host 0.0.0.0 --port 7860 --reload --reload-dir data/raw --reload-include *.csv"]