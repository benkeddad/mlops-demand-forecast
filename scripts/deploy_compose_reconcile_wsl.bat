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

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml up -d"
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose reconciliation failed.
    pause
    exit /b 1
)

echo.
echo Current service status:
call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml ps"

echo.
echo =======================================================
echo   Checking LocalStack (S3) for DVC Remote Storage
echo =======================================================
echo.

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/setup_localstack_bucket.sh"

echo.
echo ===================================================
echo   Launching Application Interfaces and Live Logging...
echo ===================================================

start "Rossmann FastAPI App Console" wsl -u root bash -c "while true; do docker logs -f rossmann_api; sleep 2; done"

start "MLflow Tracking Console" wsl -u root bash -c "while true; do docker logs -f rossmann_mlflow; sleep 2; done"

start "Prefect Orchestration Console" wsl -u root bash -c "while true; do docker logs -f rossmann_prefect; sleep 2; done"

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
