@echo off

:: Claude added these two lines: (1) enabledelayedexpansion was missing, so the
:: !WAIT_COUNT! check below never actually worked; (2) this script now lives in
:: scripts/, so jump back to the repo root first - everything below assumes that CWD.
setlocal enabledelayedexpansion
cd /d "%~dp0.."

:: WSL-Docker variant of deploy_k3s_clean.bat: identical logic, except the
:: custom image builds run against the Docker Engine installed inside the
:: WSL Ubuntu distro (faster) instead of Docker Desktop.

echo =======================================================
echo   Checking Docker Engine inside WSL Ubuntu
echo =======================================================
echo.

where wsl >nul 2>&1
if errorlevel 1 (
    echo ERROR: WSL is not installed on this machine.
    echo Install WSL with an Ubuntu distro and Docker Engine before running this script.
    pause
    exit /b 1
)

wsl -u root docker version >nul 2>&1
if errorlevel 1 (
    echo Docker daemon inside WSL is not running. Attempting to start it...
    wsl -u root systemctl start docker >nul 2>&1

    wsl -u root docker version >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Docker is not installed, or could not be started, inside the WSL Ubuntu distro.
        echo Install the Docker Engine inside WSL Ubuntu, then run this script again.
        pause
        exit /b 1
    )

    echo Docker daemon started successfully.
) else (
    echo Docker daemon inside WSL is already running.
)

echo Docker Engine was found inside WSL. Using it instead of Docker Desktop.
echo.

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

if not exist "deploy\terraform" mkdir deploy\terraform
wsl -u root cat /etc/rancher/k3s/k3s.yaml > deploy\terraform\k3s.yaml

echo =======================================================
echo   [3/6] Pre-loading Base Distro Images into K3s Cache...
echo =======================================================

echo Pulling Postgres...
wsl -u root k3s ctr -n k8s.io images pull docker.io/library/postgres:15-alpine

echo Pulling Redis...
wsl -u root k3s ctr -n k8s.io images pull docker.io/library/redis:7-alpine

echo Images successfully cached!

echo =======================================================
echo   [4/6] Building and Loading Custom API Docker Image
echo =======================================================

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker build -t rossmann-api:latest -f docker/api.Dockerfile ."
if errorlevel 1 (
    echo ERROR: docker build failed. Aborting.
    pause
    exit /b 1
)

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker save rossmann-api:latest -o rossmann-api.tar"
if errorlevel 1 (
    echo ERROR: docker save failed. Aborting.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%') && k3s ctr -n k8s.io images import rossmann-api.tar"
if errorlevel 1 (
    echo ERROR: API image import failed. Aborting.
    pause
    exit /b 1
)

del rossmann-api.tar

echo Building and importing custom MLflow image...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker build -t rossmann-mlflow:latest -f docker/mlflow.Dockerfile ."
if errorlevel 1 (
    echo ERROR: mlflow docker build failed. Aborting.
    pause
    exit /b 1
)

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker save rossmann-mlflow:latest -o rossmann-mlflow.tar"
if errorlevel 1 (
    echo ERROR: mlflow docker save failed. Aborting.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%') && k3s ctr -n k8s.io images import rossmann-mlflow.tar"
if errorlevel 1 (
    echo ERROR: MLflow image import failed. Aborting.
    pause
    exit /b 1
)

del rossmann-mlflow.tar

echo Building and importing custom Prefect image...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker build -t rossmann-prefect:latest -f docker/prefect.Dockerfile ."
if errorlevel 1 (
    echo ERROR: prefect docker build failed. Aborting.
    pause
    exit /b 1
)

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker save rossmann-prefect:latest -o rossmann-prefect.tar"
if errorlevel 1 (
    echo ERROR: prefect docker save failed. Aborting.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%') && k3s ctr -n k8s.io images import rossmann-prefect.tar"
if errorlevel 1 (
    echo ERROR: Prefect image import failed. Aborting.
    pause
    exit /b 1
)

del rossmann-prefect.tar

echo =======================================================
echo   [5/6] Verifying Terraform Natively inside WSL...
echo =======================================================

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/install_terraform.sh"
if errorlevel 1 (
    echo ERROR: Terraform install/check failed. Aborting.
    pause
    exit /b 1
)

echo =======================================================
echo   [6/6] Performing Full Clean Start and Deployment
echo =======================================================

echo Deleting existing application resources and persistent data...

wsl -u root k3s kubectl delete ^
deployment/postgres ^
deployment/redis ^
deployment/mlflow ^
deployment/prefect ^
deployment/rossmann-api ^
service/postgres ^
service/redis ^
service/mlflow ^
service/prefect ^
service/rossmann-api-service ^
configmap/postgres-init-config ^
pvc/postgres-data-pvc ^
pvc/mlflow-data-pvc ^
pvc/prefect-data-pvc ^
--ignore-not-found

if errorlevel 1 (
    echo ERROR: Kubernetes resource cleanup failed. Aborting.
    pause
    exit /b 1
)

echo Waiting for persistent volume claims to be fully deleted...
set /a PVC_WAIT_COUNT=0

:wait_pvc_deletion
wsl -u root bash -c "k3s kubectl get pvc postgres-data-pvc >/dev/null 2>&1 || k3s kubectl get pvc mlflow-data-pvc >/dev/null 2>&1 || k3s kubectl get pvc prefect-data-pvc >/dev/null 2>&1"

if not errorlevel 1 (
    set /a PVC_WAIT_COUNT+=1

    if !PVC_WAIT_COUNT! GEQ 40 (
        echo.
        echo ERROR: Persistent volume claims were not deleted after 2 minutes.
        pause
        exit /b 1
    )

    timeout /t 3 /nobreak >nul
    goto wait_pvc_deletion
)

echo Persistent volume claims have been deleted.

echo Removing previous Terraform state...

if exist "deploy\terraform\terraform.tfstate" (
    del /f /q "deploy\terraform\terraform.tfstate"
)

if exist "deploy\terraform\terraform.tfstate.backup" (
    del /f /q "deploy\terraform\terraform.tfstate.backup"
)

if exist "deploy\terraform\.terraform.tfstate.lock.info" (
    del /f /q "deploy\terraform\.terraform.tfstate.lock.info"
)

echo Previous Terraform state removed.

wsl -u root bash -c "cd $(wslpath '%CD%')/deploy/terraform && terraform init"
if errorlevel 1 (
    echo ERROR: terraform init failed. Aborting.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%')/deploy/terraform && terraform apply -auto-approve"
if errorlevel 1 (
    echo ERROR: terraform apply failed. Aborting.
    pause
    exit /b 1
)

wsl -u root k3s kubectl rollout restart deployment/rossmann-api
if errorlevel 1 (
    echo ERROR: API rollout restart failed. Aborting.
    pause
    exit /b 1
)

wsl -u root k3s kubectl rollout status deployment/rossmann-api --timeout=120s
if errorlevel 1 (
    echo ERROR: API deployment did not become ready within 120 seconds.
    pause
    exit /b 1
)

echo.
echo =======================================================
echo   Launching Application Interfaces and Live Logging...
echo =======================================================

start "Rossmann FastAPI App Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/rossmann-api-service 8000:8000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/rossmann-api; sleep 2; done"

start "MLflow Tracking Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/mlflow 5000:5000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/mlflow; sleep 2; done"

start "Prefect Orchestration Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/prefect 4200:4200 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/prefect; sleep 2; done"

start "PostgreSQL Database Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/postgres 5432:5432 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/postgres; sleep 2; done"

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
