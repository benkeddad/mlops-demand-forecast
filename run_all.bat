echo =======================================================
echo   [1/6] Resetting WSL Subsystem & Starting K3s Server
echo =======================================================
:: Gracefully stops all WSL instances to instantly clear any ghost volume storage locks
echo Resetting WSL to guarantee clean storage mounts...
wsl --shutdown
timeout /t 3 /nobreak >nul

:: Open K3s in a fresh window using the native loopback setup
start "K3s Engine (DO NOT CLOSE)" wsl -u root k3s server --bind-address=127.0.0.1

echo Waiting for Kubernetes API to Wake Up...
set /a WAIT_COUNT=0
:wait_k3s
wsl -u root k3s kubectl get nodes >nul 2>&1
if errorlevel 1 (
    set /a WAIT_COUNT+=1
    if !WAIT_COUNT! GEQ 40 (
        echo.
        echo ERROR: K3s did not come up after 2 minutes.
        pause
        exit /b 1
    )
    timeout /t 3 /nobreak >nul
    goto wait_k3s
)
echo Kubernetes API is Online.

echo =======================================================
echo   [2/6] Preparing Terraform Credentials...
echo =======================================================
if not exist "terraform" mkdir terraform
wsl -u root cat /etc/rancher/k3s/k3s.yaml > terraform\k3s.yaml

echo =======================================================
echo   [3/6] Pre-loading Base Distro Images into K3s Cache...
echo =======================================================
echo Pulling Postgres...
wsl -u root k3s ctr -n k8s.io images pull docker.io/library/postgres:15-alpine
echo Pulling Redis...
wsl -u root k3s ctr -n k8s.io images pull docker.io/library/redis:7-alpine
echo Pulling MLflow...
wsl -u root k3s ctr -n k8s.io images pull docker.io/mlflow/mlflow:latest
echo Pulling Prefect...
wsl -u root k3s ctr -n k8s.io images pull docker.io/prefecthq/prefect:2.14-python3.10
echo Images successfully cached!

echo =======================================================
echo   [4/6] Building and Loading Custom API Docker Image
echo =======================================================
call docker build -t rossmann-api:latest .
if errorlevel 1 (
    echo ERROR: docker build failed. Aborting.
    pause
    exit /b 1
)

call docker save rossmann-api:latest -o rossmann-api.tar
if errorlevel 1 (
    echo ERROR: docker save failed. Aborting.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%') && k3s ctr -n k8s.io images import rossmann-api.tar"
del rossmann-api.tar

echo =======================================================
echo   [5/6] Verifying Terraform Natively inside WSL...
echo =======================================================
wsl -u root bash -c "bash $(wslpath '%CD%')/install_terraform.sh"
if errorlevel 1 (
    echo ERROR: Terraform install/check failed. Aborting.
    pause
    exit /b 1
)

echo =======================================================
echo   [6/6] Cleaning Old Cluster State & Deploying Natively
echo =======================================================
wsl -u root k3s kubectl delete deployment/postgres deployment/redis deployment/mlflow deployment/prefect deployment/rossmann-api service/postgres service/redis service/mlflow service/prefect service/rossmann-api-service pvc/postgres-data-pvc pvc/mlflow-data-pvc pvc/prefect-data-pvc configmap/postgres-init-config --ignore-not-found

wsl -u root bash -c "cd $(wslpath '%CD%')/terraform && terraform init"
if errorlevel 1 (
    echo ERROR: terraform init failed. Aborting.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%')/terraform && terraform apply -auto-approve"
if errorlevel 1 (
    echo ERROR: terraform apply failed. Aborting.
    pause
    exit /b 1
)

wsl -u root k3s kubectl rollout restart deployment/rossmann-api
wsl -u root k3s kubectl rollout status deployment/rossmann-api --timeout=120s

echo.
echo =======================================================
echo   Launching Application Interfaces and Live Logging...
echo =======================================================

start "Rossmann FastAPI App Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/rossmann-api-service 8000:8000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/rossmann-api; sleep 2; done"

start "MLflow Tracking Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/mlflow 5000:5000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/mlflow; sleep 2; done"

start "Prefect Orchestration Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/prefect 4200:4200 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/prefect; sleep 2; done"

start "PostgreSQL Database Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/postgres 5433:5432 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/postgres; sleep 2; done"

echo.
echo =======================================================
echo   Deployment Complete -- The MLOps Pipeline is Live.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo =======================================================
pause
exit /b 0