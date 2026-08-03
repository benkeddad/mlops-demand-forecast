@echo off
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

:: Name of the k3d cluster this script reconciles against. Must match the
:: name deploy_k3s_clean_wsl.bat creates - k3d runs K3s itself inside
:: Docker containers instead of installing it directly on the WSL host, so
:: cluster lifecycle goes through the k3d CLI instead of systemctl, and
:: kubectl is a separate binary rather than bundled into the k3s binary
:: the way "k3s kubectl" was.
set "K3D_CLUSTER=rossmann"

:: Non-destructive K3s reconciliation, with image builds run against the
:: Docker Engine installed inside the WSL Ubuntu distro (not Docker Desktop's
:: own engine). It also calls Docker directly now for the LocalStack image
:: pull and the Compose-conflict check (k3d image import needs a local
:: Docker image to import, and there's no bundled "k3s ctr" equivalent to
:: pull straight from a registry the way bare K3s could).

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
echo Ensuring LocalStack 4.4.0 image is cached in k3d...
wsl -u root docker pull docker.io/localstack/localstack:4.4.0
wsl -u root k3d image import docker.io/localstack/localstack:4.4.0 -c %K3D_CLUSTER%

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
echo   Rossmann MLOps Non-Destructive Recovery Startup
echo =======================================================
echo.
echo This script will NOT delete:
echo   - PersistentVolumeClaims
echo   - Persistent data
echo   - Terraform state
echo   - Deployments
echo   - Services
echo   - ConfigMaps
echo.
echo Healthy resources will be skipped.
echo Unhealthy deployments will be restarted.
echo Missing resources will be recreated by Terraform.
echo =======================================================
echo.

echo =======================================================
echo   [1/6] Checking the k3d Cluster
echo =======================================================

wsl -u root k3d cluster list %K3D_CLUSTER% >nul 2>&1

if errorlevel 1 (
    :: No cluster by this name exists yet - this is effectively a first run,
    :: so create it fresh instead of erroring out the way "systemctl start"
    :: on a never-installed service would have. See deploy_k3s_clean_wsl.bat
    :: for why each port is mapped straight through: every Service in
    :: deploy/terraform/main.tf is type: LoadBalancer on its own distinct
    :: port, so k3d's built-in ServiceLB reaches them directly with no
    :: Ingress/hostname routing and no kubectl port-forward tunnel involved.
    echo K3d cluster "%K3D_CLUSTER%" does not exist yet. Creating it...
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
) else (
    echo K3d cluster "%K3D_CLUSTER%" exists. Making sure it is running...
    wsl -u root k3d cluster start %K3D_CLUSTER%

    if errorlevel 1 (
        echo ERROR: K3d cluster could not be started.
        pause
        exit /b 1
    )
)

echo Waiting for Kubernetes API...
set /a WAIT_COUNT=0

:wait_k3s
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get nodes >nul 2>&1

if errorlevel 1 (
    set /a WAIT_COUNT+=1

    if !WAIT_COUNT! GEQ 40 (
        echo.
        echo ERROR: Kubernetes API did not become available after 2 minutes.
        pause
        exit /b 1
    )

    timeout /t 3 /nobreak >nul
    goto wait_k3s
)

echo Kubernetes API is online.

echo.
echo Current cluster node status:
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get nodes

echo =======================================================
echo   [2/6] Preparing Terraform Credentials
echo =======================================================

if not exist "deploy\terraform" (
    echo ERROR: deploy\terraform directory does not exist.
    pause
    exit /b 1
)

wsl -u root k3d kubeconfig get %K3D_CLUSTER% > deploy\terraform\k3s.yaml

if errorlevel 1 (
    echo ERROR: Failed to copy the K3s kubeconfig.
    pause
    exit /b 1
)

echo Terraform kubeconfig is ready.

echo =======================================================
echo   [3/6] Checking Terraform
echo =======================================================

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/install_terraform.sh"

if errorlevel 1 (
    echo ERROR: Terraform install/check failed.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%')/deploy/terraform && terraform init"

if errorlevel 1 (
    echo ERROR: terraform init failed.
    pause
    exit /b 1
)

echo Terraform is initialized.

echo =======================================================
echo   [4/6] Checking Required Kubernetes Resources
echo =======================================================

set "NEED_TERRAFORM_APPLY=0"

echo Checking ConfigMap postgres-init-config...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get configmap postgres-init-config >nul 2>&1

if errorlevel 1 (
    echo MISSING: configmap/postgres-init-config
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: configmap/postgres-init-config
)

echo Checking PersistentVolumeClaim postgres-data-pvc...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pvc postgres-data-pvc >nul 2>&1

if errorlevel 1 (
    echo MISSING: pvc/postgres-data-pvc
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: pvc/postgres-data-pvc
)

echo Checking PersistentVolumeClaim mlflow-data-pvc...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pvc mlflow-data-pvc >nul 2>&1

if errorlevel 1 (
    echo MISSING: pvc/mlflow-data-pvc
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: pvc/mlflow-data-pvc
)

echo Checking PersistentVolumeClaim prefect-data-pvc...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pvc prefect-data-pvc >nul 2>&1

if errorlevel 1 (
    echo MISSING: pvc/prefect-data-pvc
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: pvc/prefect-data-pvc
)

echo Checking Service postgres...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get service postgres >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/postgres
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/postgres
)

echo Checking Service redis...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get service redis >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/redis
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/redis
)

echo Checking Service mlflow...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get service mlflow >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/mlflow
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/mlflow
)

echo Checking Service prefect...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get service prefect >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/prefect
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/prefect
)

echo Checking Service rossmann-api-service...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get service rossmann-api-service >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/rossmann-api-service
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/rossmann-api-service
)

echo Checking Deployment postgres...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployment postgres >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/postgres
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/postgres
)

echo Checking Deployment redis...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployment redis >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/redis
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/redis
)

echo Checking Deployment mlflow...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployment mlflow >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/mlflow
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/mlflow
)

echo Checking Deployment prefect...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployment prefect >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/prefect
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/prefect
)

echo Checking Deployment rossmann-api...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployment rossmann-api >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/rossmann-api
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/rossmann-api
)

echo Checking Deployment localstack...
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployment localstack >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/localstack
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/localstack
)

echo.

if "!NEED_TERRAFORM_APPLY!"=="1" (
    echo One or more required resources are missing.
    echo Running Terraform to recreate only missing resources...

    wsl -u root bash -c "cd $(wslpath '%CD%')/deploy/terraform && terraform apply -auto-approve"

    if errorlevel 1 (
        echo ERROR: Terraform could not recreate the missing resources.
        pause
        exit /b 1
    )

    echo Terraform reconciliation completed.
) else (
    echo All required Kubernetes resources exist.
    echo Skipping terraform apply to save startup time.
)

echo =======================================================
echo   [5/6] Checking Deployment Health
echo =======================================================

echo.
echo Checking PostgreSQL deployment...

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/postgres --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo PostgreSQL is not healthy. Restarting deployment/postgres...

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/postgres

    if errorlevel 1 (
        echo ERROR: PostgreSQL restart command failed.
        pause
        exit /b 1
    )

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/postgres --timeout=180s

    if errorlevel 1 (
        echo ERROR: PostgreSQL did not become ready after restart.
        echo.
        wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
        pause
        exit /b 1
    )
) else (
    echo PostgreSQL is healthy. Skipping restart.
)

echo.
echo Checking Redis deployment...

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/redis --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo Redis is not healthy. Restarting deployment/redis...

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/redis

    if errorlevel 1 (
        echo ERROR: Redis restart command failed.
        pause
        exit /b 1
    )

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/redis --timeout=180s

    if errorlevel 1 (
        echo ERROR: Redis did not become ready after restart.
        echo.
        wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
        pause
        exit /b 1
    )
) else (
    echo Redis is healthy. Skipping restart.
)

echo.
echo Checking MLflow deployment...

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/mlflow --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo MLflow is not healthy. Restarting deployment/mlflow...

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/mlflow

    if errorlevel 1 (
        echo ERROR: MLflow restart command failed.
        pause
        exit /b 1
    )

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/mlflow --timeout=180s

    if errorlevel 1 (
        echo ERROR: MLflow did not become ready after restart.
        echo.
        wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
        pause
        exit /b 1
    )
) else (
    echo MLflow is healthy. Skipping restart.
)

echo.
echo Checking Prefect deployment...

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/prefect --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo Prefect is not healthy. Restarting deployment/prefect...

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/prefect

    if errorlevel 1 (
        echo ERROR: Prefect restart command failed.
        pause
        exit /b 1
    )

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/prefect --timeout=180s

    if errorlevel 1 (
        echo ERROR: Prefect did not become ready after restart.
        echo.
        wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
        pause
        exit /b 1
    )
) else (
    echo Prefect is healthy. Skipping restart.
)

echo.
echo Checking Rossmann API deployment...

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/rossmann-api --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo Rossmann API is not healthy. Restarting deployment/rossmann-api...

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/rossmann-api

    if errorlevel 1 (
        echo ERROR: Rossmann API restart command failed.
        pause
        exit /b 1
    )

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/rossmann-api --timeout=300s

    if errorlevel 1 (
        echo ERROR: Rossmann API did not become ready after restart.
        echo.
        wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
        pause
        exit /b 1
    )
) else (
    echo Rossmann API is healthy. Skipping restart.
)

echo.
echo Checking LocalStack deployment...

wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/localstack --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo LocalStack is not healthy. Restarting deployment/localstack...

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout restart deployment/localstack

    if errorlevel 1 (
        echo ERROR: LocalStack restart command failed.
        pause
        exit /b 1
    )

    wsl -u root kubectl --context k3d-%K3D_CLUSTER% rollout status deployment/localstack --timeout=120s

    if errorlevel 1 (
        echo ERROR: LocalStack did not become ready after restart.
        echo.
        wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
        pause
        exit /b 1
    )
) else (
    echo LocalStack is healthy. Skipping restart.
)

echo.
echo All deployments are available.

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

echo =======================================================
echo   [6/6] Launching Interfaces and Live Logs
echo =======================================================

echo.
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get deployments
echo.
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pods
echo.
wsl -u root kubectl --context k3d-%K3D_CLUSTER% get pvc
echo.

:: These used to also run a "kubectl port-forward ...; sleep 3" retry loop
:: alongside the log tail, since a port-forward tunnel dies (and has to be
:: re-established) every time its target pod restarts. k3d's port mapping
:: (set once at cluster-creation time) routes through the Service instead
:: of a specific pod IP, so it survives pod restarts on its own - these
:: consoles only need to tail logs now.
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
echo   Recovery Startup Complete
echo =======================================================
echo   No persistent data was deleted.
echo   Healthy deployments were not restarted.
echo.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo   LocalStack (S3):  localhost:4566
echo =======================================================

pause
exit /b 0
