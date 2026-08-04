@echo on
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

:: Non-destructive Compose reconciliation, run against the Docker Engine
:: installed inside the WSL Ubuntu distro (not Docker Desktop's own engine).
:: The only supported reconcile-Compose script - LocalStack (needed for S3)
:: only runs inside WSL anyway, so a Docker-Desktop-only variant added nothing.

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

wsl -u root docker compose version >nul 2>&1
if errorlevel 1 (
    echo ERROR: The docker compose plugin is not available inside the WSL Ubuntu distro.
    echo Install the docker-compose-plugin package inside WSL Ubuntu, then run this script again.
    pause
    exit /b 1
)

echo Docker Engine and Compose were found inside WSL. Using them instead of Docker Desktop.
echo.

echo =======================================================
echo   Freeing Ports Held by a Running K3s Deployment
echo =======================================================
echo.
echo Docker Compose and the K3s deployment publish the same host ports
echo (8000, 5000, 4200, 5432, 4566), so only one stack can serve them
echo at a time. Checking whether K3s currently owns them...
echo.

wsl -u root systemctl is-active --quiet k3s
if not errorlevel 1 (
    echo K3s is running - stopping it so Compose can bind its ports cleanly.
    echo K3s's own ServiceLB binds LoadBalancer ports directly on this host,
    echo independent of any kubectl port-forward tunnel, so only stopping
    echo k3s itself actually releases them. Cluster state/PVCs are left
    echo untouched; restart K3s any time with scripts\deploy_k3s_reconcile_wsl.bat.
    wsl -u root pkill -f "port-forward" >nul 2>&1
    wsl -u root systemctl stop k3s

    set /a K3S_STOP_WAIT=0
    :wait_k3s_stop_reconcile_compose
    wsl -u root systemctl is-active --quiet k3s
    if not errorlevel 1 (
        set /a K3S_STOP_WAIT+=1
        if !K3S_STOP_WAIT! GEQ 20 (
            echo.
            echo ERROR: K3s did not stop within 40 seconds.
            pause
            exit /b 1
        )
        timeout /t 2 /nobreak >nul
        goto wait_k3s_stop_reconcile_compose
    )

    echo K3s stopped. Giving containerd a moment to release its host ports...
    timeout /t 3 /nobreak >nul
) else (
    echo K3s is not running. No port conflicts to resolve.
)
echo.

echo ===================================================
echo   Docker Compose Non-Destructive Reconciliation
echo ===================================================
echo.
echo Existing containers and volumes will be preserved.
echo Healthy and unchanged containers will not be recreated.
echo.

echo [1/2] Checking the Docker Compose configuration...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml config --quiet"
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose configuration is invalid.
    pause
    exit /b 1
)

echo Docker Compose configuration is valid.

echo.
echo [2/2] Reconciling Docker Compose services...

:: api is deliberately excluded here and reconciled only after PostgreSQL is
:: seeded below - otherwise a freshly-started/restarted api container's
:: entrypoint would reach its training stage against a still-empty database.
call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml up -d postgres redis localstack mlflow prefect"
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose reconciliation failed.
    pause
    exit /b 1
)

echo.
echo =======================================================
echo   Preparing LocalStack (S3) and PostgreSQL Seed Data
echo =======================================================
echo.

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/setup_localstack_and_postgres.sh"
if errorlevel 1 (
    echo.
    echo ERROR: LocalStack/PostgreSQL bootstrap failed.
    pause
    exit /b 1
)

echo.
echo Reconciling the Rossmann API service now that PostgreSQL is seeded...
call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml up -d api"
if errorlevel 1 (
    echo.
    echo ERROR: Starting the Rossmann API service failed.
    pause
    exit /b 1
)

echo.
echo Current service status:
call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml ps"

echo.
echo ===================================================
echo   Launching Application Interfaces and Live Logging...
echo ===================================================

taskkill /FI "WINDOWTITLE eq Rossmann FastAPI App Console*" /F >nul 2>&1
start "Rossmann FastAPI App Console" wsl -u root bash -c "while true; do docker logs -f rossmann_api; sleep 2; done"

taskkill /FI "WINDOWTITLE eq MLflow Tracking Console*" /F >nul 2>&1
start "MLflow Tracking Console" wsl -u root bash -c "while true; do docker logs -f rossmann_mlflow; sleep 2; done"

taskkill /FI "WINDOWTITLE eq Prefect Orchestration Console*" /F >nul 2>&1
start "Prefect Orchestration Console" wsl -u root bash -c "while true; do docker logs -f rossmann_prefect; sleep 2; done"

taskkill /FI "WINDOWTITLE eq PostgreSQL Database Console*" /F >nul 2>&1
start "PostgreSQL Database Console" wsl -u root bash -c "while true; do docker logs -f rossmann_postgres; sleep 2; done"

echo.
echo ===================================================
echo   Reconciliation completed successfully.
echo.
echo   Existing volumes were preserved.
echo   Healthy unchanged containers were preserved.
echo   Missing or stopped services were started.
echo.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo   LocalStack (S3):  localhost:4566
echo ===================================================

pause
exit /b 0
