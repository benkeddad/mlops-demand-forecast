@echo off

:: Claude added these two lines: (1) enabledelayedexpansion was missing, so the
:: !WAIT_COUNT! check below never actually worked; (2) this script now lives in
:: scripts/, so jump back to the repo root first - everything below assumes that CWD.
setlocal enabledelayedexpansion
cd /d "%~dp0.."

:: Name of the k3d cluster this script creates. k3d runs K3s itself
:: inside Docker containers instead of installing it directly on the
:: WSL host, so cluster lifecycle goes through the k3d CLI instead of
:: systemctl, and kubectl is a separate binary rather than bundled
:: into the k3s binary the way "k3s kubectl" was.
set "K3D_CLUSTER=rossmann"

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
echo   Checking k3d and kubectl inside WSL Ubuntu
echo =======================================================
echo.

wsl -u root k3d version >nul 2>&1
if errorlevel 1 (
    echo ERROR: k3d is not installed, or not on root's PATH, inside WSL Ubuntu.
    echo Install it with:
    echo   wsl -u root bash -c "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh ^| bash"
    pause
    exit /b 1
)

wsl -u root kubectl version --client >nul 2>&1
if errorlevel 1 (
    echo ERROR: kubectl is not installed, or not on root's PATH, inside WSL Ubuntu.
    echo Unlike the k3s binary, k3d does not bundle its own kubectl - install it
    echo separately, e.g.:
    echo   wsl -u root bash -c "curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl ^&^& install -m 0755 kubectl /usr/local/bin/kubectl"
    pause
    exit /b 1
)

echo k3d and kubectl were found inside WSL.
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
echo   [1/6] Resetting WSL Subsystem ^& Recreating the k3d Cluster
echo =======================================================

:: Gracefully stops all WSL instances to instantly clear any ghost volume storage locks
echo Resetting WSL to guarantee clean storage mounts...
wsl --shutdown
timeout /t 3 /nobreak >nul

:: wsl --shutdown above also killed the Docker daemon checked earlier in
:: this script, along with the k3d cluster's containers - Docker has to
:: come back up before k3d, or step [4/6]'s "docker build", can run.
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

:: The reset above left the k3d cluster's containers stopped (if they
:: existed at all) rather than actually removed. Delete the cluster
:: outright and recreate it from scratch - the guaranteed-clean-slate
:: this script promises - instead of just restarting the old one.
echo Removing any existing k3d cluster named "%K3D_CLUSTER%"...
wsl -u root k3d cluster delete %K3D_CLUSTER% >nul 2>&1

:: Every service in deploy/terraform/main.tf is type: LoadBalancer on its
:: own distinct port (8000/5000/4200/5432/4566, exactly what Compose also
:: publishes) - k3d's built-in ServiceLB fulfills those directly, so
:: mapping each port straight through at cluster-creation time reaches
:: them with no Ingress/hostname routing involved, and no kubectl
:: port-forward tunnel to babysit or reconnect after a pod restart.
echo Creating a fresh k3d cluster "%K3D_CLUSTER%"...
wsl -u root k3d cluster create %K3D_CLUSTER% ^
    --api-port 6550 ^
    -p "8000:8000@loadbalancer" ^
    -p "5000:5000@loadbalancer" ^
    -p "4200:4200@loadbalancer" ^
    -p "5432:5432@loadbalancer" ^
    -p "4566:4566@loadbalancer" ^
    --wait --timeout 120s
if errorlevel 1 (
    echo ERROR: k3d cluster create failed.
    pause
    exit /b 1
)

echo Waiting for Kubernetes API to Wake Up...
set /a WAIT_COUNT=0

:wait_k3s
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get nodes >nul 2>&1
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
wsl -u root k3d kubeconfig get %K3D_CLUSTER% > deploy\terraform\k3s.yaml

echo =======================================================
echo   [3/6] Pre-loading Base Distro Images into K3s Cache...
echo =======================================================

:: k3d has no bundled "ctr images pull" - the image has to exist as a local
:: Docker image first, then k3d image import loads it straight into every
:: node's containerd (no intermediate tar file needed, unlike step [4/6]'s
:: custom images used to require).
echo Pulling Postgres...
wsl -u root docker pull docker.io/library/postgres:15-alpine
wsl -u root k3d image import docker.io/library/postgres:15-alpine -c %K3D_CLUSTER%

echo Pulling Redis...
wsl -u root docker pull docker.io/library/redis:7-alpine
wsl -u root k3d image import docker.io/library/redis:7-alpine -c %K3D_CLUSTER%

echo Pulling LocalStack 4.4.0...
wsl -u root docker pull docker.io/localstack/localstack:4.4.0
wsl -u root k3d image import docker.io/localstack/localstack:4.4.0 -c %K3D_CLUSTER%

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

wsl -u root k3d image import rossmann-api:latest -c %K3D_CLUSTER%
if errorlevel 1 (
    echo ERROR: API image import failed. Aborting.
    pause
    exit /b 1
)

echo Building and importing custom MLflow image...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker build -t rossmann-mlflow:latest -f docker/mlflow.Dockerfile ."
if errorlevel 1 (
    echo ERROR: mlflow docker build failed. Aborting.
    pause
    exit /b 1
)

wsl -u root k3d image import rossmann-mlflow:latest -c %K3D_CLUSTER%
if errorlevel 1 (
    echo ERROR: MLflow image import failed. Aborting.
    pause
    exit /b 1
)

echo Building and importing custom Prefect image...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker build -t rossmann-prefect:latest -f docker/prefect.Dockerfile ."
if errorlevel 1 (
    echo ERROR: prefect docker build failed. Aborting.
    pause
    exit /b 1
)

wsl -u root k3d image import rossmann-prefect:latest -c %K3D_CLUSTER%
if errorlevel 1 (
    echo ERROR: Prefect image import failed. Aborting.
    pause
    exit /b 1
)

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

:: No manual "kubectl delete" pass needed here anymore: step [1/6] already
:: deleted and recreated the entire k3d cluster, so there is nothing left
:: over for Terraform to fight with, and no PVC-deletion wait loop needed
:: either - deleting the cluster means the PersistentVolumes backing those
:: claims are already gone. Only Terraform's own state needs resetting so
:: it doesn't think stale resources from a previous cluster still exist.

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

:: Port 4566 is already reachable at this point - k3d mapped it straight
:: through to svc/localstack at cluster-creation time, so unlike the old
:: kubectl port-forward setup there's no tunnel that has to exist first
:: before setup_localstack_bucket.sh's check against 127.0.0.1:4566 works.
taskkill /FI "WINDOWTITLE eq LocalStack S3 Console*" /F >nul 2>&1
start "LocalStack S3 Console" wsl -u root bash -c "while true; do kubectl --context k3d-%K3D_CLUSTER% logs -f deployment/localstack; sleep 2; done"

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/setup_localstack_bucket.sh"

echo.

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/rossmann-api
if errorlevel 1 (
    echo ERROR: API rollout restart failed. Aborting.
    pause
    exit /b 1
)

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/rossmann-api --timeout=120s
if errorlevel 1 (
    echo ERROR: API deployment did not become ready within 120 seconds.
    pause
    exit /b 1
)

echo.
echo =======================================================
echo   Launching Application Interfaces and Live Logging...
echo =======================================================

:: These used to also run a "kubectl port-forward ...; sleep 3" retry loop
:: alongside the log tail, since a port-forward tunnel dies (and has to be
:: re-established) every time its target pod restarts. k3d's port mapping
:: (set once at cluster-creation time in step [1/6]) routes through the
:: Service instead of a specific pod IP, so it survives pod restarts on its
:: own - these consoles only need to tail logs now.
taskkill /FI "WINDOWTITLE eq Rossmann FastAPI App Console*" /F >nul 2>&1
start "Rossmann FastAPI App Console" wsl -u root bash -c "while true; do kubectl --context k3d-%K3D_CLUSTER% logs -f deployment/rossmann-api; sleep 2; done"

taskkill /FI "WINDOWTITLE eq MLflow Tracking Console*" /F >nul 2>&1
start "MLflow Tracking Console" wsl -u root bash -c "while true; do kubectl --context k3d-%K3D_CLUSTER% logs -f deployment/mlflow; sleep 2; done"

taskkill /FI "WINDOWTITLE eq Prefect Orchestration Console*" /F >nul 2>&1
start "Prefect Orchestration Console" wsl -u root bash -c "while true; do kubectl --context k3d-%K3D_CLUSTER% logs -f deployment/prefect; sleep 2; done"

taskkill /FI "WINDOWTITLE eq PostgreSQL Database Console*" /F >nul 2>&1
start "PostgreSQL Database Console" wsl -u root bash -c "while true; do kubectl --context k3d-%K3D_CLUSTER% logs -f deployment/postgres; sleep 2; done"

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
