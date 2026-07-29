@echo on
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

:: WSL-Docker variant of scriptsdeploy_compose_reconcile.bat: identical logic,
:: except every Docker / Docker Compose command runs against the Docker
:: Engine installed inside the WSL Ubuntu distro (faster) instead of Docker
:: Desktop.

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
echo   Checking LocalStack (S3) for DVC Remote Storage
echo =======================================================
echo.

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/setup_localstack_bucket.sh"

echo.

echo =======================================================
echo   Checking Administrator Privileges
echo =======================================================
echo.

net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: This script must be run as Administrator so it can map WSL ports to Windows localhost.
    echo Right-click this script and choose "Run as administrator", then run it again.
    pause
    exit /b 1
)

echo Administrator privileges confirmed.
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
echo ===================================================
echo   Mapping Windows localhost to the WSL Docker containers
echo ===================================================
echo.

echo Resolving current WSL IP address...
for /f "tokens=1" %%A in ('wsl hostname -I') do set "WSL_IP=%%A"
if not defined WSL_IP (echo ERROR: Unable to resolve the WSL IP address. & pause & exit /b 1)

echo WSL IP address: %WSL_IP%

for %%P in (8000 5000 4200 5432 6379) do (netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=%%P >nul 2>&1 & netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=%%P connectaddress=%WSL_IP% connectport=%%P >nul)

echo All ports mapped from Windows localhost to WSL IP %WSL_IP%.
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
echo ===================================================

pause
exit /b 0
