@echo off

:: Claude added these two lines: (1) enabledelayedexpansion was missing, so the
:: !WAIT_COUNT! check below never actually worked; (2) this script now lives in
:: scripts/, so jump back to the repo root first - everything below assumes that CWD.
setlocal enabledelayedexpansion
cd /d "%~dp0.."

:: Destructive full K3s rebuild, with image builds run against the Docker
:: Engine installed inside the WSL Ubuntu distro (not Docker Desktop's own
:: engine). The only supported clean-K3s script - LocalStack (needed for S3)
:: only runs inside WSL anyway, so a Docker-Desktop-only variant added nothing.
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
echo   Freeing Ports Held by a Running Docker Compose Stack
echo =======================================================
echo.
echo Docker Compose and the K3s deployment publish the same host ports
echo (8000, 5000, 4200, 5432, 4566), so only one stack can serve them
echo at a time. Checking whether Compose currently owns them...
echo.

set "COMPOSE_RUNNING="
for /f "delims=" %%i in ('wsl -u root docker ps -q -f "name=rossmann_api" 2^>nul') do set "COMPOSE_RUNNING=%%i"

if defined COMPOSE_RUNNING (
    echo Docker Compose stack is running - stopping its containers so K3s
    echo can bind cleanly. Data and images are preserved; restart Compose
    echo any time with scripts\deploy_compose_reconcile_wsl.bat.
    call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml stop"
) else (
    echo Docker Compose is not running. No port conflicts to resolve.
)
echo.

echo =======================================================
echo   [1/6] Resetting WSL Subsystem & Starting K3s Server
echo =======================================================

:: Gracefully stops all WSL instances to instantly clear any ghost volume storage locks
echo Resetting WSL to guarantee clean storage mounts...
wsl --shutdown
timeout /t 3 /nobreak >nul

:: wsl --shutdown above also killed the Docker daemon checked earlier in
:: this script, so it has to come back up before step [4/6] can "docker build".
echo Restarting the Docker Engine inside WSL Ubuntu after the reset...
wsl -u root systemctl start docker >nul 2>&1

set /a DOCKER_WAIT_COUNT=0
:wait_docker_after_shutdown
wsl -u root docker version >nul 2>&1
if errorlevel 1 (
    set /a DOCKER_WAIT_COUNT+=1
    if !DOCKER_WAIT_COUNT! GEQ 20 (
        echo.
        echo ERROR: Docker did not come back up inside WSL after the reset.
        pause
        exit /b 1
    )
    timeout /t 3 /nobreak >nul
    goto wait_docker_after_shutdown
)
echo Docker Engine is back online.
echo.

:: Restart K3s as the systemd-managed service - the same service
:: deploy_k3s_reconcile_wsl.bat manages via systemctl - instead of a bare
:: "k3s server" process. Two different ways of starting k3s would race
:: each other for ports 6443/10250 the moment both scripts get run in
:: the same session, which is exactly the failure this fixes.
echo Restarting the K3s service...
wsl -u root systemctl restart k3s
if errorlevel 1 (
    echo ERROR: K3s service could not be restarted. Is k3s installed as a
    echo systemd service inside the WSL Ubuntu distro?
    pause
    exit /b 1
)

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

echo Pulling LocalStack 4.4.0...
wsl -u root k3s ctr -n k8s.io images pull docker.io/localstack/localstack:4.4.0

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
deployment/localstack ^
service/postgres ^
service/redis ^
service/mlflow ^
service/prefect ^
service/rossmann-api-service ^
service/localstack ^
configmap/postgres-init-config ^
pvc/postgres-data-pvc ^
pvc/mlflow-data-pvc ^
pvc/prefect-data-pvc ^
secret/postgres-credentials ^
secret/s3-credentials ^
secret/rossmann-ingress-tls ^
ingress/rossmann-ingress ^
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

echo =======================================================
echo   Checking LocalStack (S3) for DVC Remote Storage
echo =======================================================
echo.

:: Started here (before the bucket check) rather than down with the other
:: consoles - setup_localstack_bucket.sh checks 127.0.0.1:4566 from inside
:: WSL, which only resolves once this tunnel exists.
taskkill /FI "WINDOWTITLE eq LocalStack S3 Console*" /F >nul 2>&1
start "LocalStack S3 Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/localstack 4566:4566 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/localstack; sleep 2; done"

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/setup_localstack_bucket.sh"

echo.

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

taskkill /FI "WINDOWTITLE eq Rossmann FastAPI App Console*" /F >nul 2>&1
start "Rossmann FastAPI App Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/rossmann-api-service 8000:8000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/rossmann-api; sleep 2; done"

taskkill /FI "WINDOWTITLE eq MLflow Tracking Console*" /F >nul 2>&1
start "MLflow Tracking Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/mlflow 5000:5000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/mlflow; sleep 2; done"

taskkill /FI "WINDOWTITLE eq Prefect Orchestration Console*" /F >nul 2>&1
start "Prefect Orchestration Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/prefect 4200:4200 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/prefect; sleep 2; done"

taskkill /FI "WINDOWTITLE eq PostgreSQL Database Console*" /F >nul 2>&1
start "PostgreSQL Database Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/postgres 5432:5432 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/postgres; sleep 2; done"

echo.
echo =======================================================
echo   Deployment Complete -- The MLOps Pipeline is Live.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo   LocalStack (S3):  localhost:4566
echo =======================================================

pause
exit /b 0
