@echo on
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

:: WSL-Docker variant of deploy_compose_clean.bat: identical logic, except
:: every Docker / Docker Compose command runs against the Docker Engine
:: installed inside the WSL Ubuntu distro (faster) instead of Docker Desktop.

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

echo =======================================================
echo   Docker Compose Full Clean Deployment
echo =======================================================
echo.
echo WARNING:
echo This script permanently deletes all Docker Compose data
echo belonging to this project, including:
echo.
echo   - Running and stopped project containers
echo   - Project networks
echo   - Project named volumes
echo   - Project anonymous volumes
echo   - Postgres persistent data
echo   - MLflow persistent data
echo   - Locally built project images
echo   - Orphaned project containers
echo.
echo Unrelated Docker projects will not be touched.
echo =======================================================
echo.

echo [1/3] Destroying the existing Docker Compose stack...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml down --volumes --rmi all --remove-orphans"
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose destruction failed.
    pause
    exit /b 1
)

echo.
echo Existing project containers, volumes, networks, images,
echo and orphaned containers have been removed.

echo.
echo [2/3] Rebuilding every image from scratch...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml build --no-cache --pull"
if errorlevel 1 (
    echo.
    echo ERROR: Docker image rebuild failed.
    pause
    exit /b 1
)

echo.
echo [3/3] Creating a completely new Docker Compose stack...

call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml up -d --force-recreate --renew-anon-volumes"
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose startup failed.
    pause
    exit /b 1
)

echo.
echo Current Docker Compose status:
call wsl -u root bash -c "cd $(wslpath '%CD%') && docker compose -f deploy/docker-compose.yaml ps"

if errorlevel 1 (
    echo.
    echo ERROR: Unable to retrieve Docker Compose status.
    pause
    exit /b 1
)

echo.
echo =======================================================
echo   Checking LocalStack (S3) for DVC Remote Storage
echo =======================================================
echo.

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/setup_localstack_bucket.sh"

echo.
echo =======================================================
echo   Mapping Windows localhost to the WSL Docker containers
echo =======================================================
echo.

echo Resolving current WSL IP address...
for /f "tokens=1" %%A in ('wsl hostname -I') do set "WSL_IP=%%A"
if not defined WSL_IP (echo ERROR: Unable to resolve the WSL IP address. & pause & exit /b 1)

echo WSL IP address: %WSL_IP%

for %%P in (8000 5000 4200 5432 6379 4566) do (netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=%%P >nul 2>&1 & netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=%%P connectaddress=%WSL_IP% connectport=%%P >nul)

echo All ports mapped from Windows localhost to WSL IP %WSL_IP%.
echo.

echo =======================================================
echo   Launching Application Interfaces and Live Logging...
echo =======================================================

start "Rossmann FastAPI App Console" wsl -u root bash -c "while true; do docker logs -f rossmann_api; sleep 2; done"

start "MLflow Tracking Console" wsl -u root bash -c "while true; do docker logs -f rossmann_mlflow; sleep 2; done"

start "Prefect Orchestration Console" wsl -u root bash -c "while true; do docker logs -f rossmann_prefect; sleep 2; done"

start "PostgreSQL Database Console" wsl -u root bash -c "while true; do docker logs -f rossmann_postgres; sleep 2; done"

echo.
echo =======================================================
echo   Full Clean Deployment Completed
echo =======================================================
echo.
echo   All project containers were recreated.
echo   All project volumes were recreated.
echo   All project images were rebuilt without cache.
echo   All previous project data was permanently deleted.
echo.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo =======================================================

pause
exit /b 0
